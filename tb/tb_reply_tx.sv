`timescale 1ns/1ps

// Self-checking testbench for reply_tx.
//   iverilog -g2012 -s tb_reply_tx -o t.vvp board/reply_tx.sv tb/tb_reply_tx.sv && vvp -n t.vvp
//
// A model predicts the byte stream: when idle, done -> [A6][seq][d0..d3], else err -> [E6][seq]
// (done wins if both come together); events while a reply is being sent are dropped.
// The fake uart_tx sink takes a byte when tx_valid && tx_ready, with ready high 100%, ~50% and
// ~10% of the time. Checked every cycle: busy, tx_valid == busy, tx_data held while not taken,
// every byte in order, and no bytes left over at the end.
module tb_reply_tx;
    parameter int N_CYCLES = 6000;      // per ready setting

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic done = 0, err = 0, tx_ready = 0;
    logic [6:0] done_seq = 0, err_seq = 0;
    logic [3:0][3:0] digits = 0;
    logic [7:0] tx_data;
    logic tx_valid, busy;

    reply_tx dut (.*);

    // expected bytes
    logic [7:0] exp_b [0:65535];
    int wr = 0, rd = 0, mleft = 0;
    int errors = 0;
    int n_ok = 0, n_err = 0, n_both = 0, n_dropped = 0;
    logic       prev_hold = 0;          // last cycle: valid but not taken
    logic [7:0] prev_data;
    int ready_pct = 100;
    int c, i;

    task automatic fail(input string msg);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("FAIL @%0t: %s", $time, msg);
        end
    endtask

    always @(posedge clk) if (rst_n) begin
        if (busy !== (mleft != 0)) fail($sformatf("busy = %b, expected %b", busy, mleft != 0));
        if (tx_valid !== busy) fail("tx_valid differs from busy");
        if (prev_hold && tx_data !== prev_data)
            fail($sformatf("tx_data changed from %02h to %02h before it was taken", prev_data, tx_data));
        prev_hold = tx_valid && !tx_ready;
        prev_data = tx_data;

        if (mleft == 0) begin
            if (done) begin
                exp_b[wr] = 8'hA6; exp_b[wr+1] = {1'b0, done_seq};
                for (i = 0; i < 4; i++) exp_b[wr+2+i] = {4'b0, digits[i]};
                wr = wr + 6; mleft = 6; n_ok = n_ok + 1;
                if (err) n_both = n_both + 1;
            end else if (err) begin
                exp_b[wr] = 8'hE6; exp_b[wr+1] = {1'b0, err_seq};
                wr = wr + 2; mleft = 2; n_err = n_err + 1;
            end
        end else begin
            if (done || err) n_dropped = n_dropped + 1;
            if (tx_valid && tx_ready) begin
                if (tx_data !== exp_b[rd]) fail($sformatf("byte %0d = %02h, expected %02h", rd, tx_data, exp_b[rd]));
                rd = rd + 1; mleft = mleft - 1;
            end
        end
    end

    // stimulus on the falling edge
    task automatic stim(input int cycles);
        begin
            for (c = 0; c < cycles; c++) begin
                @(negedge clk);
                tx_ready <= ($urandom % 100) < ready_pct;
                done     <= ($urandom % 100) < 4;
                err      <= ($urandom % 100) < 4;
                done_seq <= 7'($urandom);
                err_seq  <= 7'($urandom);
                for (i = 0; i < 4; i++) digits[i] <= 4'($urandom % 10);
            end
            @(negedge clk); done <= 0; err <= 0; tx_ready <= 1;
            repeat (40) @(negedge clk);        // drain
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        // directed: both in the same idle cycle -> only the OK reply
        done <= 1; err <= 1; done_seq <= 7'd5; err_seq <= 7'd9; digits <= 16'h3210; tx_ready <= 1;
        @(negedge clk); done <= 0; err <= 0;
        repeat (20) @(negedge clk);

        ready_pct = 100; stim(N_CYCLES);
        ready_pct = 50;  stim(N_CYCLES);
        ready_pct = 10;  stim(N_CYCLES);

        if (rd != wr)  fail($sformatf("%0d bytes predicted, %0d sent", wr, rd));
        if (n_both == 0 || n_dropped == 0 || n_err == 0) fail("stimulus did not cover both-at-once / dropped / error replies");
        if (errors == 0)
            $display("PASS: %0d OK replies, %0d error replies, %0d both-at-once (done won), %0d dropped while busy, %0d bytes",
                     n_ok, n_err, n_both, n_dropped, rd);
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule