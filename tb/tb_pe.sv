`timescale 1ns/1ps

// Self-checking testbench for pe8 (processing element = mac8 + forwarding registers).
//
// Checks, every clock cycle:
//   1. Forwarding: a_out, b_out, a_valid_out, b_valid_out and clear_out equal
//      the inputs from one cycle earlier.
//   2. Accumulation: acc matches a reference model that only accumulates when
//      BOTH a_valid_in and b_valid_in are high.
//
// Run:
//   iverilog -g2012 -o sim.vvp rtl/mac8.sv rtl/pe8.sv tb/tb_pe8.sv && vvp sim.vvp
//   vvp sim.vvp +seed=42      (different random sequence)

module tb_pe8;

    // ------------------------------------------------------------------
    // Signals
    // ------------------------------------------------------------------
    logic clk = 0, rst_n = 0;
    parameter int MAC_LAT = 2;

    logic signed [7:0]  a_in = 0, b_in = 0;
    logic               a_valid_in = 0, b_valid_in = 0, clear_in = 0;

    logic signed [7:0]  a_out, b_out;
    logic               a_valid_out, b_valid_out, clear_out;
    logic signed [31:0] acc;

    // ------------------------------------------------------------------
    // DUT and clock
    // ------------------------------------------------------------------
    pe8 #(.MAC_LAT(MAC_LAT)) dut (.*);

    always #5 clk = ~clk;   // 10 ns period

    // ------------------------------------------------------------------
    // Reference model and bookkeeping
    // ------------------------------------------------------------------
    int expected_acc = 0;   // what acc SHOULD be
    int errors       = 0;
    int checks       = 0;

    // Inputs applied last cycle = what the outputs should show this cycle
    logic signed [7:0] prev_a = 0, prev_b = 0;
    logic              prev_a_valid = 0, prev_b_valid = 0, prev_clear = 0;

    // Drive inputs on the falling edge (away from the rising edge the DUT samples on)
    // and update the reference model the same way the DUT will on the next rising edge.
    task automatic drive(input logic signed [7:0] a, input logic signed [7:0] b,
                         input logic va, input logic vb, input logic clr);
        a_in       = a;
        b_in       = b;
        a_valid_in = va;
        b_valid_in = vb;
        clear_in   = clr;

        prev_a       = a;
        prev_b       = b;
        prev_a_valid = va;
        prev_b_valid = vb;
        prev_clear   = clr;

        if (clr)
            expected_acc = (va && vb) ? int'(a) * int'(b) : 0;
        else if (va && vb)
            expected_acc = expected_acc + int'(a) * int'(b);
    endtask

    // Compare every output against what it should be after the last rising edge.
    task automatic check(input string label);
        checks++;
        if (a_out !== prev_a || b_out !== prev_b ||
            a_valid_out !== prev_a_valid || b_valid_out !== prev_b_valid ||
            clear_out !== prev_clear) begin
            $display("FAIL [%s] forwarding: a_out=%0d (exp %0d) b_out=%0d (exp %0d) va=%b (exp %b) vb=%b (exp %b) clr=%b (exp %b)",
                     label, a_out, prev_a, b_out, prev_b,
                     a_valid_out, prev_a_valid, b_valid_out, prev_b_valid,
                     clear_out, prev_clear);
            errors++;
        end
        if (acc !== expected_acc) begin
            $display("FAIL [%s] acc = %0d, expected %0d", label, acc, expected_acc);
            errors++;
        end
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    int seed;

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_pe8: seed = %0d", seed);
        void'($urandom(seed));

        // Reset: drive non-zero inputs while rst_n is low. A correct PE ignores
        // them and keeps every output at 0; a PE with no reset would copy them.
        a_in = 5; b_in = -3; a_valid_in = 1; b_valid_in = 1; clear_in = 1;
        #8;   // past the first rising edge (5 ns) while still in reset
        if (a_out !== 0 || b_out !== 0 || a_valid_out !== 0 || b_valid_out !== 0 ||
            clear_out !== 0 || acc !== 0) begin
            $display("FAIL [reset] outputs not 0 during reset: a_out=%0d b_out=%0d va=%b vb=%b clr=%b acc=%0d",
                     a_out, b_out, a_valid_out, b_valid_out, clear_out, acc);
            errors++;
        end
        checks++;

        // Return inputs to idle before releasing reset
        a_in = 0; b_in = 0; a_valid_in = 0; b_valid_in = 0; clear_in = 0;
        #4 rst_n = 1;

        // --- Directed tests -------------------------------------------
        @(negedge clk); drive( 3,  4, 1, 1, 1);           // new sum: 12
        @(negedge clk); check("3*4 with clear");
                        drive( 2,  5, 1, 1, 0);           // 12 + 10 = 22
        @(negedge clk); check("+2*5");
                        drive( 7,  7, 1, 0, 0);           // only a valid: hold 22
        @(negedge clk); check("only a valid");
                        drive( 7,  7, 0, 1, 0);           // only b valid: hold 22
        @(negedge clk); check("only b valid");
                        drive(-3,  2, 1, 1, 1);           // new sum: -6
        @(negedge clk); check("-3*2 with clear");
                        drive(-128, -128, 1, 1, 1);       // new sum: 16384
        @(negedge clk); check("-128*-128");
                        drive(-128,  127, 1, 1, 0);       // 16384 - 16256 = 128
        @(negedge clk); check("+(-128*127)");
                        drive( 9,  9, 0, 0, 1);           // clear, nothing valid: 0
        @(negedge clk); check("clear only");
                        drive( 0,  0, 0, 0, 0);

        // --- Random test ----------------------------------------------
        for (int n = 0; n < 5000; n++) begin
            @(negedge clk);
            check($sformatf("random cycle %0d", n));
            drive($urandom, $urandom,
                  ($urandom_range(0, 3) != 0),     // a valid 75% of the time
                  ($urandom_range(0, 3) != 0),     // b valid 75% of the time
                  ($urandom_range(0, 19) == 0));   // clear 5% of the time
        end
        @(negedge clk); check("final");

        // --- Summary ---------------------------------------------------
        if (errors == 0) $display("PASS: all %0d checks passed", checks);
        else             $display("FAIL: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule