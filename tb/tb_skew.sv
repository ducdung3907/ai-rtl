`timescale 1ns/1ps

// Self-checking testbench for skew (input skewing for the systolic array).
//
// Expected behaviour:
//   lane i output = lane i input from exactly i cycles ago
//   data, valid and start of a lane are delayed by the same amount
//   lane 0 has no delay (straight through)
//   after reset, every delayed valid_out / start_out is 0
//   (data registers are not reset, so data is only checked once real inputs arrive)
//
// Tests:
//   1. Reset: drive valid/start high WHILE reset is held; delayed lanes must stay 0
//   2. Counting pattern: lane i of column k = 10*k + i, printed as a table
//   3. Random: random data, valid and start for many cycles, every lane checked
//
// Run:
//   iverilog -g2012 -o sim.vvp rtl/skew.sv tb/tb_skew.sv && vvp sim.vvp
//   iverilog -g2012 -Ptb_skew.N=8 -o sim.vvp rtl/skew.sv tb/tb_skew.sv    (other sizes)
//   vvp sim.vvp +seed=42                                                  (other random sequence)

module tb_skew;

    parameter int N             = 4;
    parameter int RANDOM_CYCLES = 2000;

    localparam int MAX_CYCLES = RANDOM_CYCLES + 100;   // size of the input history

    // ------------------------------------------------------------------
    // Signals
    // ------------------------------------------------------------------
    logic clk = 0, rst_n = 0;

    logic [N-1:0][7:0] data_in  = '0;
    logic              valid_in = 0;
    logic              start_in = 0;

    logic [N-1:0][7:0] data_out;
    logic [N-1:0]      valid_out;
    logic [N-1:0]      start_out;

    // ------------------------------------------------------------------
    // DUT and clock
    // ------------------------------------------------------------------
    skew #(.N(N)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start_in  (start_in),
        .data_in   (data_in),
        .valid_in  (valid_in),
        .data_out  (data_out),
        .valid_out (valid_out),
        .start_out (start_out)
    );

    always #5 clk = ~clk;   // 10 ns period

    // ------------------------------------------------------------------
    // Input history: what was driven on each cycle since reset was released.
    // Lane i's output now should equal the history entry from i cycles ago.
    // ------------------------------------------------------------------
    logic [7:0] hist_data  [MAX_CYCLES][N];
    logic       hist_valid [MAX_CYCLES];
    logic       hist_start [MAX_CYCLES];

    int cycle  = 0;      // cycles since reset release
    int errors = 0;
    int checks = 0;
    int i, src;          // declared once, assigned in loops (Icarus quirk)

    // Drive one column of inputs and record it in the history
    task automatic drive(input logic v, input logic s);
        valid_in = v;
        start_in = s;
        hist_valid[cycle] = v;
        hist_start[cycle] = s;
        for (i = 0; i < N; i++)
            hist_data[cycle][i] = data_in[i];
    endtask

    // Check every lane against the history
    task automatic check_lanes(input string label);
        #1;   // let lane 0 (combinational) settle
        for (i = 0; i < N; i++) begin
            src = cycle - i;            // the cycle this lane's output came from
            checks++;
            if (src >= 0) begin
                if (data_out[i]  !== hist_data[src][i] ||
                    valid_out[i] !== hist_valid[src]   ||
                    start_out[i] !== hist_start[src]) begin
                    errors++;
                    if (errors <= 10)
                        $display("FAIL [%s] cycle %0d lane %0d: got data=%0d valid=%b start=%b, expected data=%0d valid=%b start=%b (input from cycle %0d)",
                                 label, cycle, i, data_out[i], valid_out[i], start_out[i],
                                 hist_data[src][i], hist_valid[src], hist_start[src], src);
                end
            end else begin
                // Lane hasn't received anything since reset: control must be 0
                if (valid_out[i] !== 1'b0 || start_out[i] !== 1'b0) begin
                    errors++;
                    if (errors <= 10)
                        $display("FAIL [%s] cycle %0d lane %0d: valid=%b start=%b before any input arrived (expected 0)",
                                 label, cycle, i, valid_out[i], start_out[i]);
                end
            end
        end
        cycle++;
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    int seed;

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_skew: N = %0d, seed = %0d", N, seed);
        void'($urandom(seed));

        // --- 1. Reset ---------------------------------------------------
        // Drive valid/start high with the clock running while reset is held.
        // Registered lanes (1..N-1) must ignore them and stay 0.
        // Lane 0 is a wire, so it follows the input even in reset.
        valid_in = 1; start_in = 1;
        for (i = 0; i < N; i++) data_in[i] = 8'hAA;
        repeat (3) @(negedge clk);
        for (i = 1; i < N; i++) begin
            checks++;
            if (valid_out[i] !== 1'b0 || start_out[i] !== 1'b0) begin
                errors++;
                $display("FAIL [reset] lane %0d: valid=%b start=%b during reset (expected 0)",
                         i, valid_out[i], start_out[i]);
            end
        end
        checks++;
        if (valid_out[0] !== 1'b1 || start_out[0] !== 1'b1) begin
            errors++;
            $display("FAIL [reset] lane 0 should pass valid/start straight through");
        end

        // Idle, then release reset
        valid_in = 0; start_in = 0; data_in = '0;
        @(negedge clk);
        rst_n = 1;

        // --- 2. Counting pattern ---------------------------------------
        // Column k: lane i = 10*k + i. Easy to read: the diagonal is the skew.
        $display("");
        $display("Counting pattern (lane i of column k = 10*k + i, '--' = not valid):");
        $write("cycle |");
        for (i = 0; i < N; i++) $write(" lane %0d", i);
        $display("");

        for (int k = 0; k < N + 4; k++) begin
            @(negedge clk);
            for (i = 0; i < N; i++) data_in[i] = 10*k + i;
            drive(k < 6, k == 0);          // 6 valid columns, start on the first
            check_lanes("counting");

            $write("%5d |", cycle - 1);
            for (i = 0; i < N; i++)
                if (valid_out[i]) $write("  %5d", data_out[i]);
                else              $write("     --");
            $display("");
        end
        $display("");

        // --- 3. Random --------------------------------------------------
        for (int n = 0; n < RANDOM_CYCLES; n++) begin
            @(negedge clk);
            for (i = 0; i < N; i++) data_in[i] = $urandom;
            drive($urandom_range(0, 3) != 0,      // valid 75% of the time
                  $urandom_range(0, 9) == 0);     // start 10% of the time
            check_lanes("random");
        end

        // --- Summary ----------------------------------------------------
        if (errors == 0) $display("PASS: all %0d checks passed (N = %0d)", checks, N);
        else             $display("FAIL: %0d errors in %0d checks (N = %0d)", errors, checks, N);
        $finish;
    end

endmodule