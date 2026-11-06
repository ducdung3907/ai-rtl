`timescale 1ns/1ps

// Self-checking testbench for weight_rom, using the real image ml/mem/weights.mem.
//
// Checked:
//   - contents: every address read back equals an independent $readmemh of the same file
//   - anchors: words whose value was worked out by hand from the layout in ml/gen_mem.py
//   - timing: dout shows the word of the address presented in the PREVIOUS cycle (1-cycle latency)
//   - back-to-back reads of changing addresses (a new address every cycle), and holding an address
//   - the last address of each layer (end of layer 1 at 12543, start of layer 2 at 12544, final word)
//
// Run from the repository root (generate the image first with: python ml/gen_mem.py):
//   iverilog -g2012 -o sim.vvp board/weight_rom.sv tb/tb_weight_rom.sv -s tb_weight_rom && vvp sim.vvp

module tb_weight_rom;
    localparam int DEPTH = 12736;
    localparam int AW    = $clog2(DEPTH);

    logic clk = 0;
    always #5 clk = ~clk;

    logic [AW-1:0] addr = '0;
    logic [31:0]   dout;

    weight_rom #(.WIDTH(32), .DEPTH(DEPTH), .INIT_FILE("ml/mem/weights.mem")) dut (.*);

    logic [31:0] ref_mem [0:DEPTH-1];

    int errors = 0, checks = 0;
    task automatic fail(input string msg);
        errors++;
        if (errors <= 15) $display("FAIL @%0t: %s", $time, msg);
    endtask

    // latency check: every cycle, dout must equal ref_mem[address of the previous edge]
    logic [AW-1:0] prev_addr = '0;
    logic          started   = 0;
    always @(posedge clk) begin
        if (started) begin
            checks++;
            // sampled before this edge's update: dout holds the read of prev_addr
            if (dout !== ref_mem[prev_addr])
                fail($sformatf("addr %0d: dout = %08h, expected %08h", prev_addr, dout, ref_mem[prev_addr]));
        end
        prev_addr <= addr;
        started   <= 1;
    end

    task automatic step(input logic [AW-1:0] a);
        @(negedge clk);
        addr = a;
    endtask

    initial begin
        $readmemh("ml/mem/weights.mem", ref_mem);
        if (^ref_mem[0] === 1'bx || ^ref_mem[DEPTH-1] === 1'bx) begin
            $display("FAIL: ml/mem/weights.mem not found or too short (run from the repo root, run python ml/gen_mem.py)");
            $finish;
        end

        // anchors: layer 1 tile 2 (outputs 8..11) step 100 -> address 2*784 + 100;
        //          word = W1[100, 8..11] as bytes 0..3
        repeat (3) @(negedge clk);
        step(2*784 + 100);  @(negedge clk);
        @(negedge clk);
        if (dout !== 32'hecedc50a) fail($sformatf("anchor tile 2, k = 100: %08h, expected ecedc50a", dout));
        step(0);            @(negedge clk);
        @(negedge clk);
        if (dout !== 32'h03fdfd00) fail($sformatf("anchor address 0: %08h, expected 03fdfd00", dout));

        // sequential sweep, a new address every cycle (back to back)
        for (int a = 0; a < DEPTH; a++) step(a[AW-1:0]);

        // random addresses back to back
        for (int n = 0; n < 20000; n++) step($urandom_range(0, DEPTH - 1));

        // layer boundaries and the last word
        step(12543); step(12544); step(12545); step(DEPTH - 1); step(0); step(DEPTH - 1);

        // hold an address for several cycles
        step(777); repeat (6) @(negedge clk);

        repeat (3) @(negedge clk);
        if (errors == 0) $display("PASS: %0d reads correct (contents, anchors, 1-cycle latency) for %0d words", checks, DEPTH);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule