`timescale 1ns/1ps

// Self-checking testbench for pe8 (processing element = mac8 + forwarding registers).
//
// Checks, every clock cycle:
//   1. Forwarding: a_out, b_out, a_valid_out, b_valid_out and clear_out equal
//      the inputs from one cycle earlier (always 1 cycle, whatever the MAC).
//   2. Accumulation: acc matches a reference model that only accumulates when
//      BOTH a_valid_in and b_valid_in are high. The model is written for a
//      1-cycle MAC; its result is delayed MAC_LAT-1 extra cycles before the
//      comparison, so the same model checks every MAC latency.
//
// Run (MAC_LAT = 1: single-cycle mac8, 2: pipelined mac8_pipe):
//   iverilog -g2012 -Ptb_pe8.MAC_LAT=2 -o sim.vvp rtl/mac.sv rtl/pe.sv tb/tb_pe.sv && vvp sim.vvp
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
    int expected_acc = 0;   // what a 1-cycle MAC's acc would be after the next edge

    // History of expected_acc: exp_hist[0] is the newest value, exp_hist[k] is
    // k drives old. A MAC with latency MAC_LAT shows exp_hist[MAC_LAT-1].
    int exp_hist [MAC_LAT];
    initial foreach (exp_hist[k]) exp_hist[k] = 0;
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

        // Shift the history by one cycle and store the newest value
        for (int k = MAC_LAT - 1; k > 0; k--) exp_hist[k] = exp_hist[k-1];
        exp_hist[0] = expected_acc;
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
        if (acc !== exp_hist[MAC_LAT-1]) begin
            $display("FAIL [%s] acc = %0d, expected %0d", label, acc, exp_hist[MAC_LAT-1]);
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
        // them and keeps its control outputs and acc at 0. a_out and b_out are
        // deliberately NOT reset (their valid bits mark them as junk), so they
        // are not checked here.
        a_in = 5; b_in = -3; a_valid_in = 1; b_valid_in = 1; clear_in = 1;
        #8;   // past the first rising edge (5 ns) while still in reset
        if (a_valid_out !== 0 || b_valid_out !== 0 || clear_out !== 0 || acc !== 0) begin
            $display("FAIL [reset] outputs not 0 during reset: va=%b vb=%b clr=%b acc=%0d",
                     a_valid_out, b_valid_out, clear_out, acc);
            errors++;
        end
        checks++;

        // Return inputs to idle before releasing reset
        a_in = 0; b_in = 0; a_valid_in = 0; b_valid_in = 0; clear_in = 0;
        #4 rst_n = 1;

        // --- Directed tests -------------------------------------------
        // Each label names the drive just before it. With MAC_LAT = 2 the acc
        // value for a drive is checked one check later (the forwarding is not).
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

        // Idle cycles so the last few random inputs come out of the MAC pipeline
        for (int n = 0; n < MAC_LAT; n++) begin
            drive(0, 0, 0, 0, 0);
            @(negedge clk); check($sformatf("flush %0d", n));
        end

        // --- Summary ---------------------------------------------------
        if (errors == 0) $display("PASS: all %0d checks passed", checks);
        else             $display("FAIL: %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule