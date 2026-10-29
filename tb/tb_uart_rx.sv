`timescale 1ns/1ps

// Self-checking testbench for uart_rx (8N1, LSB first).
//
// A transmitter model (like the PC) drives rx using real time delays, NOT the
// FPGA clock: its bits start at random moments relative to clk, like a real
// asynchronous line, and its baud rate can be made slightly fast or slow.
// Every byte it sends is pushed into a queue; every valid pulse from the DUT
// pops the queue and compares.
//
// Tests:
//   1. Reset: rx toggling while reset is held must not produce a byte
//   2. Directed bytes: 00, FF, A5, 5A, 01, 80
//   3. Back-to-back frames (next start bit right after the stop bit)
//   4. Baud mismatch: the sender is 2.5% fast and 2.5% slow
//   5. Glitch: a short low pulse (30% of a bit) must be ignored
//   6. Framing error: stop bit = 0 must NOT produce a valid byte
//   7. Random bytes with random gaps and random clock phase
//   Always checked:
//     - valid is a single-clock pulse
//     - every valid byte matches what was sent, in order
//     - bytes received == bytes expected
//
// Run:
//   iverilog -g2012 -o sim.vvp board/uart_rx.sv tb/tb_uart_rx.sv && vvp sim.vvp
//   vvp sim.vvp +seed=7

module tb_uart_rx;

    // 100 clocks per bit: fine enough to test baud mismatch and glitches
    localparam int  CLK_HZ  = 10_000;
    localparam int  BAUD    = 100;
    localparam int  CPB     = (CLK_HZ + BAUD/2) / BAUD;
    localparam real CLK_NS  = 10.0;                 // clk period (always #5)
    localparam real BIT_NS  = CPB * CLK_NS;         // one bit time at the nominal baud
    parameter  int  N_BYTES = 200;

    logic       clk = 0, rst_n = 0;
    logic       rx = 1;                             // idle line is high
    logic [7:0] data;
    logic       valid;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (.*);

    always #5 clk = ~clk;

    logic [7:0] exp_q [$];          // bytes the DUT should report, in order
    int  expected_n = 0, received = 0, errors = 0;

    task automatic fail(input string msg);
        errors++;
        if (errors <= 10) $display("FAIL @%0t: %s", $time, msg);
    endtask

    // ------------------------------------------------------------------
    // Transmitter model (the PC). Drives rx with real-time delays.
    //   speed = 1.0 nominal, 1.025 = 2.5% fast, 0.975 = 2.5% slow
    //   good_stop = 0 sends a bad (low) stop bit: the byte must be dropped
    // ------------------------------------------------------------------
    task automatic send_byte(input logic [7:0] b,
                             input real    speed     = 1.0,
                             input bit     good_stop = 1);
        real t;
        t = BIT_NS / speed;
        if (good_stop) begin
            exp_q.push_back(b);
            expected_n++;
        end
        rx = 0;                         #(t);   // start bit
        for (int i = 0; i < 8; i++) begin
            rx = b[i];                  #(t);   // data, LSB first
        end
        rx = good_stop;                 #(t);   // stop bit
        rx = 1;                                 // back to idle
    endtask

    // Idle gap of a whole number of bit times plus a random fraction of a clock,
    // so frames start at a random phase relative to clk
    task automatic idle(input int bits);
        #(bits * BIT_NS + $urandom_range(0, 99) * CLK_NS / 100.0);
    endtask

    // ------------------------------------------------------------------
    // Monitor: compare every valid byte, and check valid is a 1-clock pulse
    // ------------------------------------------------------------------
    logic valid_d = 0;
    always @(posedge clk) begin
        #1;
        if (valid && valid_d) fail("valid stayed high for more than one clock");
        valid_d = valid;
        if (valid) begin
            received++;
            if (exp_q.size() == 0)
                fail($sformatf("unexpected byte 0x%02h (nothing was expected)", data));
            else begin
                logic [7:0] e;
                e = exp_q.pop_front();
                if (data !== e) fail($sformatf("received 0x%02h, expected 0x%02h", data, e));
            end
        end
    end

    int seed;

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_uart_rx: %0d clocks per bit, seed = %0d", CPB, seed);
        void'($urandom(seed));

        // ---- 1. Reset with activity on rx -------------------------------
        repeat (20) begin
            rx = $urandom;
            #(CLK_NS * 3);
        end
        rx = 1;
        #(CLK_NS * 5);
        rst_n = 1;
        idle(3);

        // ---- 2. Directed bytes ------------------------------------------
        send_byte(8'h00); idle(1);
        send_byte(8'hFF); idle(1);
        send_byte(8'hA5); idle(1);
        send_byte(8'h5A); idle(1);
        send_byte(8'h01); idle(1);
        send_byte(8'h80); idle(1);

        // ---- 3. Back-to-back (no idle between frames) -------------------
        repeat (10) send_byte($urandom);
        idle(2);

        // ---- 4. Baud mismatch -------------------------------------------
        repeat (10) begin send_byte($urandom, 1.025); idle(1); end   // sender 2.5% fast
        repeat (10) begin send_byte($urandom, 0.975); idle(1); end   // sender 2.5% slow

        // ---- 5. Glitch: short low pulse must not start a frame ----------
        repeat (5) begin
            rx = 0; #(0.3 * BIT_NS);
            rx = 1; idle(2);
        end
        send_byte(8'h3C); idle(2);       // a real byte right after still works

        // ---- 6. Framing error: bad stop bit must be dropped -------------
        repeat (5) begin
            send_byte($urandom, 1.0, 0); // not pushed into exp_q
            idle(2);
        end
        send_byte(8'hC3); idle(2);       // receiver recovers

        // ---- 7. Random bytes, random gaps --------------------------------
        for (int n = 0; n < N_BYTES; n++) begin
            send_byte($urandom);
            if ($urandom_range(0, 3) != 0) idle($urandom_range(0, 3));
        end

        // ---- Let the last byte come out ----------------------------------
        idle(3);

        // ---- Summary ------------------------------------------------------
        if (exp_q.size() != 0)
            fail($sformatf("%0d expected bytes never arrived", exp_q.size()));
        if (received != expected_n)
            fail($sformatf("expected %0d bytes, received %0d", expected_n, received));

        if (errors == 0) $display("PASS: %0d bytes received correctly (glitches and bad frames ignored)", received);
        else             $display("FAIL: %0d errors (%0d expected, %0d received)", errors, expected_n, received);
        $finish;
    end

endmodule