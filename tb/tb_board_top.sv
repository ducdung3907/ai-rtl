`timescale 1ns/1ps

// Echo test for board_top: the "PC" sends bytes into uart_rx and decodes uart_tx.
//
// The PC has its own clock, so its bit time can differ slightly from the FPGA's.
// PC_SPEED sets how fast the PC runs relative to the FPGA's baud rate:
//   1.0 = exact, 1.005 = PC 0.5% fast, 0.995 = PC 0.5% slow.
// The PC uses its own bit time for both sending and receiving, like a real UART.
//
// Run:
//   iverilog -g2012 -o sim.vvp board/uart_rx.sv board/uart_tx.sv board/board_top.sv tb/tb_board_top.sv
//   vvp sim.vvp                                       (exact speed, random gaps)
//   iverilog ... -Ptb_board_top.PC_SPEED=1.005 ...    (PC 0.5% fast)
//   iverilog ... -Ptb_board_top.GAPS=0 ...            (no gaps: continuous stream)

module tb_board_top;
    parameter real PC_SPEED = 1.0;     // PC baud / FPGA baud
    parameter int  N_BYTES  = 50;      // random bytes after the 3 directed ones
    parameter bit  GAPS     = 1;       // 1 = random idle gaps between bytes, 0 = back to back

    localparam int  CLK_HZ = 10_000, BAUD = 100;
    localparam int  CPB    = (CLK_HZ + BAUD/2) / BAUD;
    localparam real BIT_NS = CPB * 10.0 / PC_SPEED;    // the PC's bit time

    logic sys_clk = 0, sys_rst_n = 0, uart_rx = 1;
    logic uart_tx;
    logic [1:0] led;

    board_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (.*);
    always #5 sys_clk = ~sys_clk;

    logic [7:0] exp_q [$];
    int sent = 0, got = 0, errors = 0, hb_toggles = 0;

    task automatic fail(input string msg);
        errors++;
        if (errors <= 10) $display("FAIL @%0t: %s", $time, msg);
    endtask

    // PC transmitter
    task automatic pc_send(input logic [7:0] b);
        exp_q.push_back(b);
        sent++;
        uart_rx = 0;                                     #(BIT_NS);
        for (int i = 0; i < 8; i++) begin uart_rx = b[i]; #(BIT_NS); end
        uart_rx = 1;                                     #(BIT_NS);
    endtask

    // PC receiver: decode uart_tx, sampling in the middle of each bit
    initial begin
        logic [7:0] r;
        logic [7:0] e;
        wait (sys_rst_n);
        forever begin
            @(negedge uart_tx);
            #(BIT_NS / 2);
            if (uart_tx !== 0) fail("bad start bit");
            for (int i = 0; i < 8; i++) begin #(BIT_NS); r[i] = uart_tx; end
            #(BIT_NS);
            if (uart_tx !== 1) fail("bad stop bit");
            got++;
            if (exp_q.size() == 0) fail($sformatf("unexpected echo 0x%02h", r));
            else begin
                e = exp_q.pop_front();
                if (r !== e) fail($sformatf("echoed 0x%02h, expected 0x%02h", r, e));
            end
        end
    end

    // Heartbeat: count toggles of led[0]
    logic led0_d;
    always @(posedge sys_clk) begin
        led0_d <= led[0];
        if (sys_rst_n && led0_d !== led[0]) hb_toggles++;
    end

    initial begin
        logic led1_start;
        $display("tb_board_top: PC_SPEED = %0.4f, GAPS = %0d, %0d bytes", PC_SPEED, GAPS, N_BYTES + 3);

        #100;
        if (led !== 2'b11) fail($sformatf("LEDs should be off (11) in reset, got %b", led));
        sys_rst_n = 1;
        #(3 * BIT_NS);
        led1_start = led[1];

        pc_send("H"); pc_send("i"); pc_send("!");
        for (int n = 0; n < N_BYTES; n++) begin
            pc_send($urandom);
            if (GAPS) #($urandom_range(0, 2) * BIT_NS);
        end

        #(12 * BIT_NS);
        if (exp_q.size() != 0 || got != sent)
            fail($sformatf("sent %0d bytes, echoed %0d", sent, got));
        // led[1] toggles once per byte: an odd count leaves it changed
        if (((N_BYTES + 3) % 2 == 1) && led[1] === led1_start)
            fail("led[1] did not toggle once per byte");
        if (hb_toggles == 0) fail("heartbeat never toggled");

        if (errors == 0) $display("PASS: %0d bytes echoed correctly, LEDs OK", got);
        else             $display("FAIL: %0d errors (%0d sent, %0d echoed)", errors, sent, got);
        $finish;
    end
endmodule