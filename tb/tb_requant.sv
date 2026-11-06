`timescale 1ns/1ps

// Self-checking testbench for requant.
//
// Vectors come from tb/gen_requant_vectors.py (the same integer formula as ml/ref_infer.py):
//     y = clip(((acc + bias) * M + (1 << (shift - 1))) >> shift, 0, 127)
// Every line of tb/vectors/requant.hex holds: acc(8) bias(8) M(4) shift(2) expected_y(2) in hex.
//
// Checked:
//   - every output equals the expected value, in order
//   - latency: out_valid is in_valid delayed by exactly LATENCY cycles (never otherwise)
//   - back-to-back inputs and inputs with random gaps; random junk on the inputs while in_valid is low
//   - M and shift change from one input to the next (each result uses its own M and shift)
//
// Run from the repository root:
//   iverilog -g2012 -o sim.vvp board/requant.sv tb/tb_requant.sv -s tb_requant && vvp sim.vvp

module tb_requant;
    parameter int LATENCY = 3;
    localparam int MAXV = 20000;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic in_valid = 0;
    logic signed [31:0] acc = 0, bias = 0;
    logic [15:0] M = 0;
    logic [5:0] shift = 1;
    logic out_valid;
    logic signed [7:0] y;

    requant dut (.*);

    logic [95:0] mem [0:MAXV-1];
    int n = 0;
    int errors = 0, got = 0;
    logic [7:0] exp_q [$];
    logic [7:0] e;
    logic [LATENCY-1:0] pipe = '0;

    task automatic fail(input string msg);
        errors++;
        if (errors <= 15) $display("FAIL @%0t: %s", $time, msg);
    endtask

    always @(posedge clk) if (rst_n) begin
        // out_valid must be in_valid from LATENCY cycles ago (pipe[LATENCY-1] before this edge)
        if (out_valid !== pipe[LATENCY-1])
            fail($sformatf("out_valid = %b, expected %b (latency must be exactly %0d)", out_valid, pipe[LATENCY-1], LATENCY));
        if (out_valid === 1'b1) begin
            if (exp_q.size() == 0) fail("result with nothing queued");
            else begin
                e = exp_q.pop_front();
                if (y !== $signed(e)) fail($sformatf("result %0d: y = %0d, expected %0d", got, y, $signed(e)));
            end
            got++;
        end
        pipe <= {pipe[LATENCY-2:0], in_valid};
    end

    task automatic drive(input int idx, input int gap_pct);
        while ($urandom_range(0, 99) < gap_pct) begin
            in_valid = 0; acc = $urandom; bias = $urandom; M = $urandom; shift = $urandom;   // junk
            @(negedge clk);
        end
        in_valid = 1;
        acc   = mem[idx][95:64];
        bias  = mem[idx][63:32];
        M     = mem[idx][31:16];
        shift = mem[idx][13:8];
        exp_q.push_back(mem[idx][7:0]);
        @(negedge clk);
    endtask

    int seed, half;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        for (int i = 0; i < MAXV; i++) mem[i] = 'x;
        $readmemh("tb/vectors/requant.hex", mem);
        while (n < MAXV && ^mem[n] !== 1'bx) n++;
        $display("tb_requant: %0d vectors, LATENCY = %0d, seed = %0d", n, LATENCY, seed);
        void'($urandom(seed));       // after the display: $urandom(seed) overwrites seed with its RNG state
        if (n == 0) begin $display("FAIL: no vectors (run from the repository root; generate with tb/gen_requant_vectors.py)"); $finish; end

        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        half = n / 2;
        for (int i = 0; i < half; i++) drive(i, 0);           // back to back
        for (int i = half; i < n; i++) drive(i, 35);          // random gaps
        in_valid = 0;
        repeat (LATENCY + 5) @(negedge clk);

        if (got != n)               fail($sformatf("got %0d results for %0d inputs", got, n));
        if (exp_q.size() != 0)      fail($sformatf("%0d results missing", exp_q.size()));
        if (errors == 0) $display("PASS: %0d requant results correct, latency %0d (back to back and with gaps)", got, LATENCY);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule