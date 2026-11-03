`timescale 1ns/1ps
 
// Self-checking testbench for sync_fifo (first-word fall-through, valid/ready read side).
//
// Reference model: a SystemVerilog queue. Every cycle the testbench drives
// wr_valid/wr_data/rd_ready on the falling edge, checks the outputs against the
// model just before the rising edge, then updates the model the same way the
// FIFO should on that edge.
//
// Checked every cycle: rd_valid, rd_data (the oldest entry, valid in the same
// cycle: first-word fall-through), full, count, and the sticky overflow flag.
//
// Phases:
//   1. reset values
//   2. fill to full, then one more push (dropped -> overflow)
//   3. push while full WITH a pop in the same cycle (must be accepted)
//   4. drain to empty; pop while empty (ignored); push+pop on the same cycle at empty
//   5. random traffic: push-heavy, pop-heavy and balanced stretches
//
// Run:
//   iverilog -g2012 -o sim.vvp board/sync_fifo.sv tb/tb_sync_fifo.sv && vvp sim.vvp
//   iverilog ... -Ptb_sync_fifo.DEPTH=5 ...     (non-power-of-2 depth)
//   vvp sim.vvp +seed=7
 
module tb_sync_fifo;
    parameter int WIDTH  = 8;
    parameter int DEPTH  = 16;
    parameter int CYCLES = 20000;
 
    logic clk = 0, rst_n = 0;
    logic wr_valid = 0, rd_ready = 0;
    logic [WIDTH-1:0] wr_data = 0;
    logic full, rd_valid, overflow;
    logic [WIDTH-1:0] rd_data;
    logic [$clog2(DEPTH+1)-1:0] count;
 
    sync_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (.*);
    always #5 clk = ~clk;
 
    logic [WIDTH-1:0] q [$];       // reference model
    bit exp_overflow = 0;
    int errors = 0, checks = 0;
    int n_push = 0, n_pop = 0, n_drop = 0, n_full_pushpop = 0, n_empty_pushpop = 0;
 
    task automatic fail(input string msg);
        errors++;
        if (errors <= 10) $display("FAIL @%0t: %s", $time, msg);
    endtask
 
    // Drive one cycle: set inputs on the falling edge, check before the
    // rising edge, then update the model with what the edge does.
    task automatic cycle(input bit wv, input logic [WIDTH-1:0] wd, input bit rr, input string label);
        bit rd_fire, wr_fire;
        @(negedge clk);
        wr_valid = wv; wr_data = wd; rd_ready = rr;
        #1;
        checks++;
        if (rd_valid !== (q.size() > 0))
            fail($sformatf("[%s] rd_valid=%b, model has %0d entries", label, rd_valid, q.size()));
        if (q.size() > 0 && rd_data !== q[0])
            fail($sformatf("[%s] rd_data=0x%0h, expected oldest 0x%0h", label, rd_data, q[0]));
        if (full !== (q.size() == DEPTH))
            fail($sformatf("[%s] full=%b with %0d entries", label, full, q.size()));
        if (count !== q.size())
            fail($sformatf("[%s] count=%0d, expected %0d", label, count, q.size()));
        if (overflow !== exp_overflow)
            fail($sformatf("[%s] overflow=%b, expected %b", label, overflow, exp_overflow));
 
        // model update for the coming rising edge
        rd_fire = rr && (q.size() > 0);
        wr_fire = wv && ((q.size() < DEPTH) || rd_fire);
        if (wv && q.size() == DEPTH && rd_fire) n_full_pushpop++;
        if (wv && rr && q.size() == 0) n_empty_pushpop++;
        if (rd_fire) begin void'(q.pop_front()); n_pop++; end
        if (wr_fire) begin q.push_back(wd); n_push++; end
        if (wv && !wr_fire) begin exp_overflow = 1; n_drop++; end
    endtask
 
    int seed;
    int phase, pw, pr;                // random-traffic settings
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_sync_fifo: WIDTH = %0d, DEPTH = %0d, seed = %0d", WIDTH, DEPTH, seed);
        void'($urandom(seed));
 
        // 1. reset values (checked inside the first cycle)
        repeat (2) @(negedge clk);
        rst_n = 1;
        cycle(0, 0, 0, "after reset");
 
        // 2. fill to full, then one push more (dropped)
        for (int i = 0; i < DEPTH; i++) cycle(1, $urandom, 0, "fill");
        cycle(0, 0, 0, "full, idle");
        cycle(1, $urandom, 0, "push while full (dropped)");
        cycle(0, 0, 0, "overflow is sticky");
 
        // 3. push while full with a pop in the same cycle: accepted
        repeat (3) cycle(1, $urandom, 1, "push+pop at full");
 
        // 4. drain, pop while empty, push+pop at empty
        for (int i = 0; i < DEPTH + 2; i++) cycle(0, 0, 1, "drain / pop while empty");
        repeat (3) cycle(1, $urandom, 1, "push+pop at empty");
        repeat (3) cycle(0, 0, 1, "drain");
 
        // 5. random traffic in stretches
        for (int n = 0; n < CYCLES; n++) begin
            phase = (n / 200) % 3;                // 0 push-heavy, 1 pop-heavy, 2 balanced
            pw = (phase == 0) ? 70 : (phase == 1) ? 40 : 55;
            pr = (phase == 0) ? 40 : (phase == 1) ? 70 : 55;
            cycle($urandom_range(0, 99) < pw, $urandom, $urandom_range(0, 99) < pr, "random");
        end
 
        $display("pushes %0d, pops %0d, dropped %0d, push+pop at full %0d, push+pop at empty %0d",
                 n_push, n_pop, n_drop, n_full_pushpop, n_empty_pushpop);
        if (n_full_pushpop == 0 || n_drop == 0) fail("corner cases not reached");
        if (errors == 0) $display("PASS: all %0d cycles checked (DEPTH = %0d)", checks, DEPTH);
        else             $display("FAIL: %0d errors in %0d cycles (DEPTH = %0d)", errors, checks, DEPTH);
        $finish;
    end
endmodule