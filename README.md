# ai-rtl: int8 Systolic Array Matrix Multiplier

A parameterised **N×N output-stationary systolic array** in SystemVerilog that computes **C = A × B** on signed 8-bit inputs with 32-bit accumulators, the core operation of neural-network accelerators such as Google's TPU.

You feed plain matrices one column of A and one row of B per cycle; the hardware skews the inputs, streams them through N² multiply-accumulate units, and raises `done` the cycle the result is ready. Verified in simulation for N = 2 to 8 with random data, varying matrix lengths, idle cycles in the input stream and back-to-back matrices, and synthesised for FPGAs up to N = 16 (256 PEs, 114 MHz, 58 GOPS peak on an AMD Artix-7).

## Block diagram

```mermaid
flowchart LR
    A["a_col<br/>(column of A)"] --> SA["skew_a<br/>row i delayed i cycles"]
    B["b_row<br/>(row of B)"] --> SB["skew_b<br/>column j delayed j cycles"]
    V["valid / start"] --> SA
    V --> SB
    SA -- "a, valid, clear" --> ARR["N×N systolic array<br/>(N² PEs)"]
    SB -- "b, valid" --> ARR
    ARR --> C["acc[i][j] = C[i][j]"]
    L["last"] --> D["delay line<br/>2N−1 cycles"] --> DONE["done"]
```

Inside the array, `a` values move right and `b` values move down, one PE per cycle. Each PE multiplies the pair passing through it and keeps its own running sum:

```
            b[0]       b[1]       b[2]       b[3]
             ▼          ▼          ▼          ▼
a[0] ──►  PE(0,0) ──► PE(0,1) ──► PE(0,2) ──► PE(0,3)
             ▼          ▼          ▼          ▼
a[1] ──►  PE(1,0) ──► PE(1,1) ──► PE(1,2) ──► PE(1,3)
             ▼          ▼          ▼          ▼
a[2] ──►  PE(2,0) ──► PE(2,1) ──► PE(2,2) ──► PE(2,3)
             ▼          ▼          ▼          ▼
a[3] ──►  PE(3,0) ──► PE(3,1) ──► PE(3,2) ──► PE(3,3)

PE(i,j) accumulates C[i][j] = Σk A[i][k] · B[k][j]
```

## Features

- **Parameterised size N** (tested N = 2, 3, 4, 8), built with `generate` loops
- **Any inner dimension K:** an N×N array computes (N×K) × (K×N) for any K; the 32-bit accumulator has headroom for very long sums
- **Signed int8 × int8 → int32** multiply-accumulate in every PE
- **Hardware input skewing:** the array takes unskewed columns and rows straight from memory
- **Valid signals travel with the data:** idle cycles (bubbles) anywhere in the input are ignored
- **Per-row clear travelling with the data:** matrices can be streamed back to back with no gap
- **`done` signal:** pulses exactly 2N−1 cycles after the last column, on the first cycle all results are final
- **Area-aware registers:** control signals (valid, start, done) have async reset; data-path delay registers do not, since their valid bit marks them as unused

## Top-level interface: `complete_sa`

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `rst_n` | in | 1 | Asynchronous reset, active low |
| `a_col` | in | `[N-1:0][7:0]` | Column k of A: `a_col[i] = A[i][k]` |
| `b_row` | in | `[N-1:0][7:0]` | Row k of B: `b_row[j] = B[k][j]` |
| `valid` | in | 1 | This cycle's column/row is real data |
| `start` | in | 1 | First column of a new matrix (starts fresh sums) |
| `last` | in | 1 | Last column of the matrix |
| `done` | out | 1 | One-cycle pulse when every result is final |
| `acc` | out | `[N-1:0][N-1:0][31:0]` | `acc[i][j] = C[i][j]` (signed) |

**Usage:** on each cycle, drive one column of A and the matching row of B with `valid = 1`. Set `start = 1` on the first column and `last = 1` on the last (both on the same cycle if K = 1). Wait for `done`, then read `acc`.

## How it works

**Dataflow (output-stationary).** Each PE keeps one element of C. Row i of A enters from the left and moves right; column j of B enters from the top and moves down. Every PE forwards its inputs to its neighbours through registers, one cycle per hop.

**Skewing.** Data reaching PE(i,j) has passed through j PEs horizontally and i PEs vertically, so the `a` and `b` paths have different delays. To line them up, row i of A enters i cycles late and column j of B enters j cycles late. Both then reach PE(i,j) after i + j cycles, so the k-th product happens on cycle **k + i + j**. The skew module implements this with shift registers: lane i has exactly i registers, N(N−1)/2 per side.

For N = 2, the inputs reaching the array look like this:

| Cycle | Row 0 | Row 1 | Column 0 | Column 1 |
| --- | --- | --- | --- | --- |
| 0 | A00 | – | B00 | – |
| 1 | A01 | A10 | B10 | B01 |
| 2 | – | A11 | – | B11 |

**Valid and clear.** Each value carries a valid bit; a PE only accumulates when both its inputs are valid, so empty slots in the skew pattern and idle cycles in the input are ignored. The `start` signal is skewed into one clear per row and travels right with `a`, so it reaches PE(i,j) exactly when that PE's first product of a new matrix arrives (clear-and-load in one cycle). A single global clear would instead force a pause between matrices.

**Timing.** For a matrix with K columns fed on cycles 0 … K−1:

| Quantity | Value |
| --- | --- |
| Last product in PE(N−1, N−1) | cycle K + 2N − 3 |
| `done` after the last column | 2N − 1 cycles = (N−1) skew + (N−1) PE hops + 1 accumulate |
| First column to `done` | K + 2N − 2 cycles |
| Peak throughput | N² multiply-accumulates per cycle |

## Modules

| File | Module | Description |
| --- | --- | --- |
| [`rtl/mac.sv`](rtl/mac.sv) | `mac8` | Signed int8 multiply-accumulate with 32-bit accumulator, `valid` and `clear` |
| [`rtl/pe.sv`](rtl/pe.sv) | `pe8` | Processing element: `mac8` plus registers that forward a, b, valid and clear to neighbours |
| [`rtl/sa2x2.sv`](rtl/sa2x2.sv) | `sa2x2` | 2×2 array wired by hand (first step towards N×N) |
| [`rtl/saNxN.sv`](rtl/saNxN.sv) | `systolic_array` | Parameterised N×N array built with nested `generate` loops |
| [`rtl/skew.sv`](rtl/skew.sv) | `skew` | Input skewing: lane i delayed by i cycles, with valid and start |
| [`rtl/sa_top.sv`](rtl/sa_top.sv) | `complete_sa` | Top level: two skew modules, the array and the `done` delay line |

## Verification

Every testbench is self-checking: it computes the expected result with a reference model in the testbench and prints PASS or FAIL. Results below are with Icarus Verilog 12 at the default size N = 4.

| Testbench | Covers | Result |
| --- | --- | --- |
| [`tb/tb_mac.sv`](tb/tb_mac.sv) | Directed accumulate test | PASS |
| [`tb/tb_pe.sv`](tb/tb_pe.sv) | Reset, forwarding, valid gating, 5000 random cycles | PASS (5010 checks) |
| [`tb/tb_sa2x2.sv`](tb/tb_sa2x2.sv) | 6 directed matrices + 1000 random, skew done in testbench | PASS (1006 multiplications) |
| [`tb/tb_asNxN.sv`](tb/tb_asNxN.sv) | Identity, K = 1, extreme values, back-to-back, 500 random with varying K | PASS (555 multiplications) |
| [`tb/tb_skew.sv`](tb/tb_skew.sv) | Reset with inputs active, counting pattern, 2000 random cycles | PASS (8036 checks) |
| [`tb/tb_sa_top.sv`](tb/tb_sa_top.sv) | Full chain from unskewed input: directed, bubbles with junk data, back-to-back, 500 random; exact `done` timing | PASS (605 multiplications, 562 bubble cycles) |

The N×N, skew and top-level testbenches also pass at N = 2, 3 and 8. Each testbench was checked against deliberately broken versions of the design (wrong wiring, missing reset, misaligned valid, clear not travelling with the data, `done` one cycle late) to make sure it catches real bugs.

## Running the tests

Requires [Icarus Verilog](https://steveicarus.github.io/iverilog/) 12 or newer. From the repository root:

```bash
# Full system (skew + array + done)
iverilog -g2012 -o sim.vvp rtl/mac.sv rtl/pe.sv rtl/saNxN.sv rtl/skew.sv rtl/sa_top.sv tb/tb_sa_top.sv
vvp sim.vvp

# Individual blocks
iverilog -g2012 -o sim.vvp rtl/mac.sv tb/tb_mac.sv && vvp sim.vvp
iverilog -g2012 -o sim.vvp rtl/mac.sv rtl/pe.sv tb/tb_pe.sv && vvp sim.vvp
iverilog -g2012 -o sim.vvp rtl/mac.sv rtl/pe.sv rtl/sa2x2.sv tb/tb_sa2x2.sv && vvp sim.vvp
iverilog -g2012 -o sim.vvp rtl/mac.sv rtl/pe.sv rtl/saNxN.sv tb/tb_asNxN.sv && vvp sim.vvp
iverilog -g2012 -o sim.vvp rtl/skew.sv tb/tb_skew.sv && vvp sim.vvp
```

Other sizes and random seeds:

```bash
iverilog -g2012 -Ptb_complete_sa.N=8 -o sim.vvp rtl/*.sv tb/tb_sa_top.sv
vvp sim.vvp +seed=42
```

## Synthesis results

The same RTL was synthesised, placed and routed for two FPGAs with two toolflows: **AMD Artix-7** with **Vivado**, and **Lattice ECP5** with the open-source **sv2v + Yosys + nextpnr** flow. Both report area after place and route and the maximum clock frequency from static timing analysis.

| N | PEs | Artix-7 LUTs | Artix-7 max clock | ECP5 max clock | Artix-7 peak throughput |
| --- | --- | --- | --- | --- | --- |
| 2 | 4 | 530 | 128 MHz | 85.7 MHz | 1.0 GOPS |
| 4 | 16 | 2,098 | 122 MHz | 80.2 MHz | 3.9 GOPS |
| 8 | 64 | 8,424 | 121 MHz | 63.5 MHz | 15.5 GOPS |
| 12 | 144 | 18,821 | 117 MHz | – | 33.7 GOPS |
| 16 | 256 | 33,371 | 114 MHz | does not fit | 58.3 GOPS |

*Peak throughput: 2 operations (multiply + add) per PE per cycle at the maximum clock.*

### AMD Artix-7 (Vivado)

Target: **XC7A100T-1CSG324** (63,400 LUTs, 126,800 flip-flops, 240 DSP48E1 slices), the FPGA on the Nexys A7-100T and Arty A7-100T boards. `complete_sa` was synthesised out of context (`-mode out_of_context`, so its ports need no FPGA pins) with Vivado's default synthesis and implementation strategies and a 5 ns clock constraint ([`synth/timing.xdc`](synth/timing.xdc)); the maximum clock is 1 / (5 ns − WNS).

| N | PEs | LUTs | % of chip | LUTRAM | Flip-flops | DSPs | WNS at 5 ns | Max clock | Power (est.) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | 4 | 530 | 0.8% | 0 | 185 | 0 | −2.798 ns | 128 MHz | – |
| 4 | 16 | 2,098 | 3.3% | 0 | 820 | 0 | −3.205 ns | 122 MHz | – |
| 8 | 64 | 8,424 | 13% | 32 | 3,265 | 0 | −3.288 ns | 121 MHz | 0.36 W |
| 12 | 144 | 18,821 | 30% | 64 | 7,328 | 0 | −3.544 ns | 117 MHz | 0.71 W |
| 16 | 256 | 33,371 | 53% | 96 | 13,069 | 0 | −3.781 ns | 114 MHz | 1.16 W |

*Vivado 2026.1. With its default settings Vivado builds the 8×8 multipliers from LUTs and carry chains rather than DSP48 slices. Power is Vivado's vectorless estimate at the 200 MHz constraint (medium confidence), not a measurement.*

- **Area scales linearly with the number of PEs:** about 125 LUTs per PE from N = 2 to N = 16, so the size of any array can be predicted before synthesis. The flip-flop counts match Yosys' technology-independent count (183 vs 183 at N = 2 with a relaxed 10 ns constraint, 820 vs 819 at N = 4); the tight 5 ns constraint makes Vivado duplicate a few registers for timing.
- **The clock barely drops as the array grows:** 128 → 114 MHz (−11%) while the array grows 64×, so throughput scales almost linearly to 58 GOPS. Every PE only connects to its neighbours, so a bigger array does not create longer wires inside the array, and LUT-based multipliers can sit right next to their PE.
- **The critical path is the single-cycle MAC.** At N = 16 the worst path starts at PE(7,11)'s `b` forwarding register and ends at bit 30 of PE(8,11)'s accumulator: one PE hop, the multiplier and the 32-bit accumulator adder in one clock cycle. The high accumulator bits are last because the carry ripples up the adder.
- **Unreset delay lines become LUT shift registers.** From N = 8, Vivado packs the longer skew lanes into SRL shift registers (one LUT replaces a chain of flip-flops), which is why LUTRAM appears and the flip-flop count falls below Yosys' (3,265 vs 3,435 at N = 8). This is only possible because the skew data registers have no reset; the valid and start bits keep their reset and stay flip-flops.
- **Logic is optimised across module boundaries.** Vivado reports some LUTs under the `skew` instances; the netlist shows these are partial-product logic of the multipliers in the first PE column, placed next to the skew registers that feed them. Totals are unaffected.

**LUT vs DSP multipliers (N = 2).** Adding `(* use_dsp = "yes" *)` to `mac8` moves the arithmetic into DSP48E1 slices:

| N = 2 | LUTs | Flip-flops | DSPs | Max clock |
| --- | --- | --- | --- | --- |
| LUT multipliers (default) | 530 | 185 | 0 | 128 MHz |
| DSP multipliers (`use_dsp`) | 202 | 59 | 8 | 119 MHz |

The DSP version uses 62% fewer LUTs and 68% fewer flip-flops (the accumulators move into the DSPs' output registers) but is not faster, and it uses two DSPs per PE (multiply and accumulate separately). With a single-cycle MAC the DSPs' internal pipeline registers cannot be used, so the path runs through two DSP blocks in one cycle. A pipelined MAC that fits in one DSP per PE is the obvious next step.

**Size limit.** With LUT multipliers the XC7A100T fits up to roughly N = 18–20 before routing becomes difficult (N = 32 would need about twice the chip's LUTs). With one DSP per PE the 240 DSP slices allow N = 15; combining DSP and LUT PEs, or a larger device, would go further.

Elaborated RTL schematic of `complete_sa` (N = 2) and the placed N = 16 design on the chip:

![Vivado RTL schematic, N = 2](docs/vivado_rtl_schematic_N2.png)

![Placed design on the XC7A100T, N = 16](docs/vivado_device_N16.png)

### Lattice ECP5 (open-source flow)

Target: **Lattice ECP5 LFE5U-85F** (83,640 LUTs, 156 hardware 18×18 multipliers). SystemVerilog is converted to Verilog with sv2v, synthesised with Yosys and placed and routed with nextpnr.

| N | PEs | Generic gates | Flip-flops | ECP5 LUTs | ECP5 FFs | Multipliers | Max clock | Peak throughput |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | 4 | 3,264 | 183 | 540 | 295 | 4 | 85.7 MHz | 0.7 GOPS |
| 4 | 16 | 13,284 | 819 | 1,975 | 941 | 16 | 80.2 MHz | 2.6 GOPS |
| 8 | 64 | 53,291 | 3,435 | 8,172 | 3,361 | 64 | 63.5 MHz | 8.1 GOPS |

*Generic gates and flip-flops: `complete_sa` alone, technology-independent (Yosys `synth`). ECP5 columns: after place and route, including the small measurement harness. Tools: Yosys 0.33, nextpnr-ecp5 0.6, sv2v 0.0.12; other versions give slightly different numbers.*

- **Area grows linearly with the number of PEs:** about 830 generic gates, 125 ECP5 LUTs and one hardware multiplier per PE.
- **The hardware multipliers set the size limit:** with 156 of them, N = 12 (144) is the largest square array that fits; N = 16 does not.
- **The critical path is the single-cycle MAC:** PE input register → hardware multiplier → 32-bit adder → `acc`.
- **The clock falls faster than on Artix-7** (86 → 64 MHz from N = 2 to 8). Every PE must use a hard multiplier in a fixed column, so in larger arrays more PEs end up far from their multiplier and the wires get longer.

**Measurement harness.** The array has 2N×8 input and N²×32 output bits (2,048 at N = 8), far more than the FPGA's pins, and synthesis deletes any logic whose output is unused. [`synth/synth_wrap.sv`](synth/synth_wrap.sv) therefore loads the inputs from a one-pin shift register and XOR-folds all results into one 32-bit output over two register stages, so every PE is kept and the harness never limits the clock.

**Reproduce:**

```bash
./synth/synth.sh          # N = 2, 4, 8 (a few minutes); writes synth/results.csv
./synth/synth.sh 12       # larger sizes take much longer, mostly place and route
```

Requires [sv2v](https://github.com/zachjs/sv2v), [Yosys](https://github.com/YosysHQ/yosys) and [nextpnr-ecp5](https://github.com/YosysHQ/nextpnr), all available in [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build).

### Cross-tool findings

- **Same RTL, different results:** at N = 8 the Artix-7 with Vivado runs 1.9× faster than the ECP5 with the open-source flow, and the gap widens with N.
- **Hard multipliers are not automatically better.** On the ECP5 the fixed multiplier columns limit both size and clock; on the Artix-7, LUT multipliers scale further and hold the clock better, while DSP multipliers save area but need a pipelined MAC to also save time.
- **Both flows agree on the design itself:** flip-flop counts match, and both identify the single-cycle MAC as the critical path.

## Repository layout

```
rtl/      design files
tb/       self-checking testbenches
synth/    synthesis: Yosys/nextpnr script, measurement harness, results, Vivado timing constraint
docs/     figures (Vivado schematic and placed design)
```

## Limitations and next steps

- **Results are only all present between matrices.** In back-to-back streaming, early PEs start the next matrix before the last PE finishes, so `done` assumes a gap before the next `start`. Next step: copy results to an output buffer on `done` (double buffering).
- **N² × 32 output wires.** Fine for small N, impractical for large arrays. Next step: shift results out one row per cycle.
- **Single-cycle MAC.** Multiply and add in the same cycle is the critical path at every size on both FPGAs. Next step: a two-stage MAC that fits in one DSP48 per PE, then re-measure area and maximum clock against the tables above.
- **Capstone:** run an int8-quantised MNIST layer from PyTorch on the array in simulation and compare against the PyTorch result.

## AI use

- **Design (RTL):** all design files in `rtl/` were written by me. Claude reviewed them, explained concepts and pointed out bugs, which I then fixed.
- **Testbenches:** `tb/tb_mac.sv` was written by me. The other testbenches were generated by Claude and run against my designs.
- **Synthesis:** the Yosys/nextpnr script and measurement harness in `synth/` were written by Claude. The Vivado runs were set up and run by me in the Vivado GUI.
- **Documentation:** this README was drafted with Claude.

## Tools

- SystemVerilog (IEEE 1800-2012)
- Icarus Verilog 12 for simulation
- sv2v, Yosys and nextpnr for open-source synthesis and place and route (Lattice ECP5)
- AMD Vivado 2026.1 for synthesis and implementation (Artix-7)