`timescale 1ns/1ps
 
// Self-checking testbench for res_buf.
//
// Each round: drive a random acc, pulse capture for one cycle, then change acc
// immediately (the copy must not follow it). The consumer side holds out_ready
// low for random stretches. Every accepted byte is compared with the expected
// reply order: C[0][0] .. C[N-1][N-1], row by row, each value low byte first.
//
// Also checked:
//   - exactly 4*N*N bytes per capture, then busy and out_valid drop
//   - out_data stays stable while out_valid = 1 and the byte is not accepted
//   - a capture while busy is ignored (sent bytes still come from the first copy)
//   - busy = 0 and out_valid = 0 after reset
//
// Run:
//   iverilog -g2012 -o sim.vvp board/res_buf.sv tb/tb_res_buf.sv && vvp sim.vvp
//   iverilog ... -Ptb_res_buf.N=8 ...
//   vvp sim.vvp +seed=7
 
module tb_res_buf;
    parameter int N      = 4;
    parameter int ROUNDS = 200;
    localparam int NB    = 4 * N * N;
 
    logic clk = 0, rst_n = 0;
    logic [N-1:0][N-1:0][31:0] acc = '0;
    logic capture = 0, out_ready = 0;
    logic [7:0] out_data;
    logic out_valid, busy;
 
    res_buf #(.N(N)) dut (.*);
    always #5 clk = ~clk;
 
    int errors = 0, bytes_ok = 0, rounds_ok = 0;
    task automatic fail(input string msg);
        errors++;
        if (errors <= 10) $display("FAIL @%0t: %s", $time, msg);
    endtask
 
    // Expected byte b of a snapshot. With acc packed as [N-1:0][N-1:0][31:0],
    // C[i][j] sits at bits [(i*N+j)*32 +: 32], so reply byte b (row-major,
    // low byte first) is simply bits [8*b +: 8] of the flat vector.
    // (Flat vectors because Icarus cannot use variable indices into
    // multi-dimensional packed arrays.)
    function automatic logic [7:0] exp_byte(input logic [N*N*32-1:0] snap, input int b);
        return snap[8 * b +: 8];
    endfunction
 
    function automatic logic [N*N*32-1:0] rand_acc();
        logic [N*N*32-1:0] t;
        for (int k = 0; k < N * N; k++) t[32 * k +: 32] = $urandom;
        return t;
    endfunction
 
    task automatic run_round(input bit capture_while_busy);
        logic [N*N*32-1:0] snap;
        int got = 0, waits = 0;
        logic [7:0] held;
        bit holding = 0;
 
        // random acc, one-cycle capture, then scramble acc
        @(negedge clk);
        snap = rand_acc();
        acc  = snap;
        capture = 1;
        @(negedge clk);
        capture = 0;
        acc = rand_acc();
        if (busy !== 1) fail("busy not set after capture");
 
        while (got < NB && waits < 50 * NB) begin
            // a capture in the middle of sending must be ignored
            if (capture_while_busy && got == NB / 2) capture = 1;
            out_ready = ($urandom_range(0, 2) != 0);
            #1;
            if (out_valid !== 1) fail($sformatf("out_valid dropped after %0d of %0d bytes", got, NB));
            if (holding && out_data !== held)
                fail($sformatf("out_data changed while waiting: 0x%02h -> 0x%02h", held, out_data));
            if (out_ready) begin
                if (out_data !== exp_byte(snap, got))
                    fail($sformatf("byte %0d = 0x%02h, expected 0x%02h", got, out_data, exp_byte(snap, got)));
                else bytes_ok++;
                got++;
                holding = 0;
            end else begin
                held = out_data;
                holding = 1;
            end
            @(negedge clk);
            capture = 0;
            waits++;
        end
        out_ready = 0;
        #1;
        if (got != NB) fail($sformatf("only %0d of %0d bytes accepted", got, NB));
        if (busy !== 0 || out_valid !== 0) fail($sformatf("busy=%b out_valid=%b after the last byte", busy, out_valid));
        else rounds_ok++;
        repeat ($urandom_range(0, 3)) @(negedge clk);
        if (busy !== 0) fail("busy became 1 without a capture");
    endtask
 
    int seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_res_buf: N = %0d (%0d bytes per reply), seed = %0d", N, NB, seed);
        void'($urandom(seed));
 
        @(posedge clk); #1;      // rst_n starts at 0 (no negedge), so check after the first edge
        if (busy !== 0 || out_valid !== 0) fail("busy/out_valid not 0 in reset");
        repeat (2) @(negedge clk);
        rst_n = 1;
 
        for (int r = 0; r < ROUNDS; r++) run_round(r % 5 == 4);
 
        if (errors == 0) $display("PASS: %0d rounds, %0d bytes checked (N = %0d)", rounds_ok, bytes_ok, N);
        else             $display("FAIL: %0d errors (%0d rounds ok, N = %0d)", errors, rounds_ok, N);
        $finish;
    end
endmodule