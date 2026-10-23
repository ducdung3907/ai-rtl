set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/synth/build"
mkdir -p "$OUT"

SIZES=("$@")
[ ${#SIZES[@]} -eq 0 ] && SIZES=(2 4 8 12)

for tool in sv2v yosys nextpnr-ecp5; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing tool: $tool"; exit 1; }
done

# 1. SystemVerilog -> Verilog (Yosys' own parser does not handle 2D packed ports)
sv2v "$ROOT/rtl/mac.sv" "$ROOT/rtl/pe.sv" "$ROOT/rtl/saNxN.sv" "$ROOT/rtl/skew.sv" \
     "$ROOT/rtl/sa_top.sv" "$ROOT/synth/synth_wrap.sv" > "$OUT/design_sv2v.v" \
     || { echo "ERROR: sv2v failed"; exit 1; }

CSV="$ROOT/synth/results.csv"
echo "N,PEs,generic_cells,generic_ffs,ecp5_luts,ecp5_ffs,ecp5_mult18,fmax_mhz" > "$CSV"
printf "%-4s %-5s %-14s %-12s %-10s %-9s %-11s %s\n" N PEs generic_cells generic_ffs ecp5_LUTs ecp5_FFs ecp5_MULT18 fmax_MHz

# Print the end of a log and stop, so a failed step is never silent
fail() {
    echo
    echo "ERROR: $1 failed for N=$2. Last lines of $3:"
    tail -n 15 "$3"
    exit 1
}

for N in "${SIZES[@]}"; do
    # 2a. Technology-independent gate count of complete_sa itself (no harness)
    yosys -q -p "read_verilog $OUT/design_sv2v.v; chparam -set N $N complete_sa; \
                 hierarchy -top complete_sa; synth -top complete_sa -flatten; \
                 tee -o $OUT/generic_N$N.stat stat" > "$OUT/generic_N$N.log" 2>&1 \
        || fail "Generic synthesis (yosys)" "$N" "$OUT/generic_N$N.log"
    gcells=$(grep -m1 'Number of cells' "$OUT/generic_N$N.stat" | awk '{print $NF}')
    gffs=$(grep -E '\$_(S)?DFF' "$OUT/generic_N$N.stat" | awk '{s += $NF} END {print s + 0}')

    # 2b. ECP5 synthesis of the harness (keeps all logic alive with few pins)
    yosys -q -p "read_verilog $OUT/design_sv2v.v; chparam -set N $N synth_wrap; \
                 hierarchy -top synth_wrap; synth_ecp5 -top synth_wrap -json $OUT/ecp5_N$N.json" \
          > "$OUT/ecp5_N$N.log" 2>&1 \
        || fail "ECP5 synthesis (yosys)" "$N" "$OUT/ecp5_N$N.log"

    # 3. Place and route; report the achieved maximum clock frequency
    nextpnr-ecp5 --85k --package CABGA381 --json "$OUT/ecp5_N$N.json" --freq 200 --threads $(nproc) \
                 --lpf-allow-unconstrained --timing-allow-fail --seed 1 \
                 > "$OUT/pnr_N$N.log" 2>&1 \
        || fail "Place and route (nextpnr-ecp5)" "$N" "$OUT/pnr_N$N.log"
    luts=$(grep 'TRELLIS_COMB:' "$OUT/pnr_N$N.log" | tail -1 | awk '{print $3}' | cut -d/ -f1)
    ffs=$(grep 'TRELLIS_FF:'    "$OUT/pnr_N$N.log" | tail -1 | awk '{print $3}' | cut -d/ -f1)
    mul=$(grep 'MULT18X18D:'    "$OUT/pnr_N$N.log" | tail -1 | awk '{print $3}' | cut -d/ -f1)
    fmax=$(grep 'Max frequency for clock' "$OUT/pnr_N$N.log" | tail -1 | sed -E 's/.*: ([0-9.]+) MHz.*/\1/')

    echo "$N,$((N*N)),$gcells,$gffs,$luts,$ffs,$mul,$fmax" >> "$CSV"
    printf "%-4s %-5s %-14s %-12s %-10s %-9s %-11s %s\n" "$N" "$((N*N))" "$gcells" "$gffs" "$luts" "$ffs" "$mul" "$fmax"
done

echo
echo "Saved $CSV"