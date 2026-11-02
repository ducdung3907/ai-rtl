`timescale 1ns/1ps

// Self-checking testbench for uart_tx (8N1, LSB first).
//
// A receiver model (like the PC's USB-serial chip) watches tx in the background,
// decodes every frame and compares it with a queue of bytes the sender pushed.
//
// Tests:
//   1. Reset: tx = 1 (idle) and ready = 1 while reset is held, even with valid high
//   2. Directed bytes: 00, FF, A5, 5A, 01, 80
//   3. Back-to-back: valid held high, frames follow each other with no idle gap
//   4. Random: N_BYTES random bytes with random idle gaps
//   Always checked:
//     - every bit lasts exactly CPB clocks (tx is constant for the whole bit)
//     - start bit = 0, stop bit = 1, data matches what was sent
//     - ready stays low after a byte is accepted until the last clock of the
//       stop bit (where the next byte may be accepted for back-to-back frames)
//     - bytes received == bytes sent
//
// Run:
//   iverilog -g2012 -o sim.vvp board/uart_tx.sv tb/tb_uart_tx.sv && vvp sim.vvp
//   vvp sim.vvp +seed=7

module tb_uart_tx;

    // Small clock-to-baud ratio so the simulation is fast: 10 clocks per bit
    localparam int CLK_HZ  = 1000;
    localparam int BAUD    = 100;
    localparam int CPB     = (CLK_HZ + BAUD/2) / BAUD;   // clocks per bit
    localparam int FRAME   = 10 * CPB;                   // start + 8 data + stop
    parameter  int N_BYTES = 300;

    logic       clk = 0, rst_n = 0;
    logic [7:0] data = 0;
    logic       valid = 0;
    logic       ready, tx;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (.*);

    always #5 clk = ~clk;

    logic [7:0] sent_q [$];        // scoreboard: bytes sent but not yet received
    int  sent = 0, received = 0, errors = 0;
    bit  rx_busy = 0;              // receiver is in the middle of a frame

    // Count an error; print only the first 10 so one bug does not flood the log
    task automatic fail(input string msg);
        errors++;
        if (errors <= 10) $display("FAIL @%0t: %s", $time, msg);
    endtask

    // ------------------------------------------------------------------
    // Receiver: a model of the PC
    //   tx only changes right after a rising clock edge, so the receiver
    //   samples 1 time unit after every rising edge. Each bit is CPB samples;
    //   all CPB samples of a bit must be equal (bit width exactly right),
    //   and the middle sample is the bit's value.
    // ------------------------------------------------------------------
    initial begin
        logic [9:0] frame;          // [0] start, [8:1] data, [9] stop
        logic       first;
        logic [7:0] expected;

        wait (rst_n);
        forever begin
            @(negedge tx);          // the start bit begins at this clock edge
            #1;
            rx_busy = 1;
            for (int bit_i = 0; bit_i < 10; bit_i++) begin
                for (int c = 0; c < CPB; c++) begin
                    if (c == 0)       first        = tx;
                    if (c == CPB / 2) frame[bit_i] = tx;
                    if (tx !== first)
                        fail($sformatf("bit %0d of the frame changed after %0d of %0d clocks", bit_i, c, CPB));
                    if (!(bit_i == 9 && c == CPB - 1)) begin   // stay on the stop bit's last sample
                        @(posedge clk); #1;
                    end
                end
            end
            rx_busy = 0;

            if (frame[0] !== 1'b0) fail("start bit is not 0");
            if (frame[9] !== 1'b1) fail("stop bit is not 1 (framing error)");

            if (sent_q.size() == 0) begin
                fail($sformatf("received 0x%02h but nothing was sent", frame[8:1]));
            end else begin
                expected = sent_q.pop_front();
                if (frame[8:1] !== expected)
                    fail($sformatf("received 0x%02h, expected 0x%02h", frame[8:1], expected));
            end
            received++;
        end
    end

    // ------------------------------------------------------------------
    // ready monitor: after a byte is accepted (valid && ready on a rising
    // edge), ready must stay low until the last clock of the stop bit.
    // It may rise in that last clock so the next frame can follow with no gap.
    // ------------------------------------------------------------------
    int busy_left = 0;
    always @(posedge clk) begin
        if (busy_left > 0) begin
            if (ready) fail($sformatf("ready went high %0d clocks before the frame ended", busy_left));
            busy_left--;
        end
        if (rst_n && valid && ready) busy_left = FRAME - 1;   // accepted on this edge
    end

    // ------------------------------------------------------------------
    // Sender
    // ------------------------------------------------------------------
    // One byte: wait for ready, hold valid for one clock, then drop it
    task automatic send(input logic [7:0] b);
        @(negedge clk);
        while (!ready) @(negedge clk);
        data  = b;
        valid = 1;
        sent_q.push_back(b);
        sent++;
        @(negedge clk);
        valid = 0;
    endtask

    // n bytes with valid held high: each is accepted the moment ready returns
    task automatic send_back_to_back(input int n);
        @(negedge clk);
        for (int k = 0; k < n; k++) begin
            while (!ready) begin
                valid = 0;
                @(negedge clk);
            end
            data  = $urandom;
            valid = 1;
            sent_q.push_back(data);
            sent++;
            @(negedge clk);         // accepted on the rising edge before this
        end
        valid = 0;
    endtask

    int seed;

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_uart_tx: %0d clocks per bit, seed = %0d", CPB, seed);
        void'($urandom(seed));

        // ---- 1. Reset (with valid high: must not start a frame) ----------
        valid = 1;
        data  = 8'h00;
        repeat (5) begin
            @(negedge clk);
            if (tx !== 1'b1)    fail("tx must be 1 (idle) during reset");
            if (ready !== 1'b1) fail("ready must be 1 during reset");
        end
        valid = 0;
        @(negedge clk);
        rst_n = 1;
        repeat (3 * CPB) begin
            @(negedge clk);
            if (tx !== 1'b1) fail("tx left idle with no byte sent");
        end

        // ---- 2. Directed bytes -------------------------------------------
        send(8'h00);   // all zeros: only the start/stop edges
        send(8'hFF);   // all ones: looks like idle between start and stop
        send(8'hA5);   // alternating patterns
        send(8'h5A);
        send(8'h01);   // single bit at each end: catches LSB/MSB order
        send(8'h80);

        // ---- 3. Back-to-back ---------------------------------------------
        send_back_to_back(10);

        // ---- 4. Random bytes with random idle gaps -----------------------
        for (int n = 0; n < N_BYTES; n++) begin
            repeat ($urandom_range(0, 2 * CPB)) @(negedge clk);
            send($urandom);
        end

        // ---- Let the last frame finish -----------------------------------
        while (sent_q.size() != 0 || rx_busy) @(negedge clk);
        repeat (2 * CPB) @(negedge clk);

        // ---- Summary ------------------------------------------------------
        if (received != sent)
            fail($sformatf("sent %0d bytes but received %0d", sent, received));

        if (errors == 0) $display("PASS: %0d bytes sent and received correctly", sent);
        else             $display("FAIL: %0d errors (%0d sent, %0d received)", errors, sent, received);
        $finish;
    end

    // Safety net: stop if something hangs (e.g. ready never returns)
    initial begin
        #(64'd10 * (N_BYTES + 50) * (FRAME + 2 * CPB + 4));
        $display("FAIL: timeout (%0d sent, %0d received)", sent, received);
        $finish;
    end

endmodule