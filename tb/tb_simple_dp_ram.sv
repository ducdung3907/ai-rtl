`timescale 1ns/1ps

// Self-checking testbench for simple_dp_ram (one write port, one read port, both synchronous).
//
// Contract checked:
//   - a word written at edge t can be read with an address presented at edge t+1 or later
//   - the read has exactly one cycle of latency: rdata shows the word of the address of the previous edge
//   - read and write to the SAME address in the same cycle: the read returns the OLD word (read-first)
//   - we = 0 never changes the memory (junk on waddr / wdata is ignored)
//   - words not written for a long time keep their value
// Unwritten words are not checked (their power-up value is not part of the contract).
//
// Phases: directed (first / last address, same-address read-during-write), a full sweep write then read,
//         random mixed traffic with we/raddr/waddr all random.
//
// Run:
//   iverilog -g2012 -o sim.vvp board/simple_dp_ram.sv tb/tb_simple_dp_ram.sv -s tb_simple_dp_ram && vvp sim.vvp
//   iverilog ... -Ptb_simple_dp_ram.DEPTH=64 -Ptb_simple_dp_ram.WIDTH=32 ...

module tb_simple_dp_ram;
    parameter int WIDTH  = 32;
    parameter int DEPTH  = 784;
    parameter int N_RAND = 50000;

    localparam int AW = $clog2(DEPTH);

    logic clk = 0;
    always #5 clk = ~clk;

    logic we = 0;
    logic [AW-1:0] waddr = 0, raddr = 0;
    logic [WIDTH-1:0] wdata = 0, rdata;

    simple_dp_ram #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (.*);

    // reference model
    logic [WIDTH-1:0] model   [0:DEPTH-1];
    logic             written [0:DEPTH-1];
    logic             exp_valid = 0;
    logic [WIDTH-1:0] exp_val   = '0;
    logic             started   = 0;

    int errors = 0, checks = 0;
    task automatic fail(input string msg);
        errors++;
        if (errors <= 15) $display("FAIL @%0t: %s", $time, msg);
    endtask

    initial for (int i = 0; i < DEPTH; i++) written[i] = 0;

    always @(posedge clk) begin
        // 1. check the read of the previous edge
        if (started && exp_valid) begin
            checks++;
            if (rdata !== exp_val) fail($sformatf("rdata = %h, expected %h", rdata, exp_val));
        end
        // 2. what this edge reads: the OLD word (before this edge's write)
        exp_valid <= written[raddr];
        exp_val   <= model[raddr];
        started   <= 1;
        // 3. this edge's write
        if (we) begin
            model[waddr]   = wdata;
            written[waddr] = 1;
        end
    end

    // stimulus changes on the falling edge
    task automatic cycle(input logic w, input logic [AW-1:0] wa, input logic [WIDTH-1:0] wd, input logic [AW-1:0] ra);
        @(negedge clk);
        we = w; waddr = wa; wdata = wd; raddr = ra;
    endtask

    int seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_simple_dp_ram: WIDTH = %0d, DEPTH = %0d, seed = %0d", WIDTH, DEPTH, seed);
        void'($urandom(seed));

        repeat (3) @(negedge clk);

        // directed: first and last address
        cycle(1, 0,       32'hA5A5A5A5, 0);
        cycle(1, DEPTH-1, 32'h5A5A5A5A, 0);
        cycle(0, 0,       0,             0);
        cycle(0, 0,       0,             DEPTH-1);
        cycle(0, 0,       0,             0);

        // read-during-write on the same address: the read must return the OLD word
        cycle(1, 5, 32'h11111111, 5);       // old unwritten (not checked), write 11111111
        cycle(1, 5, 32'h22222222, 5);       // read returns 11111111
        cycle(1, 5, 32'h33333333, 5);       // read returns 22222222
        cycle(0, 5, 32'hdeadbeef, 5);       // read returns 33333333; we = 0 so junk write is ignored
        cycle(0, 5, 32'hdeadbeef, 5);       // still 33333333

        // full sweep: write every address, then read every address
        for (int a = 0; a < DEPTH; a++) cycle(1, a[AW-1:0], $urandom, 0);
        for (int a = 0; a < DEPTH; a++) cycle(0, $urandom, $urandom, a[AW-1:0]);

        // random mixed traffic (write enable ~50%, independent random addresses, a new read every cycle)
        for (int n = 0; n < N_RAND; n++) begin
            logic [AW-1:0] ra;
            ra = $urandom_range(0, DEPTH - 1);
            if ($urandom_range(0, 9) == 0) cycle($urandom_range(0, 1), ra, $urandom, ra);   // same address read/write
            else                           cycle($urandom_range(0, 1), $urandom_range(0, DEPTH - 1), $urandom, ra);
        end

        repeat (3) @(negedge clk);
        if (errors == 0) $display("PASS: %0d reads correct (1-cycle latency, read-first, write enable) for DEPTH = %0d", checks, DEPTH);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule