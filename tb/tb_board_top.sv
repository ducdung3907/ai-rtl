`timescale 1ns/1ps
// Echo test for board_top: the "PC" sends bytes into uart_rx and decodes uart_tx.
module tb_board_top;
    localparam int  CLK_HZ = 10_000, BAUD = 100;
    localparam int  CPB    = (CLK_HZ + BAUD/2) / BAUD;
    localparam real BIT_NS = CPB * 10.0;
    logic sys_clk = 0, sys_rst_n = 0, uart_rx = 1;
    logic uart_tx; logic [1:0] led;
    board_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (.*);
    always #5 sys_clk = ~sys_clk;

    logic [7:0] exp_q [$];
    int sent = 0, got = 0, errors = 0, hb_toggles = 0;

    task automatic pc_send(input logic [7:0] b);
        exp_q.push_back(b); sent++;
        uart_rx = 0; #(BIT_NS);
        for (int i = 0; i < 8; i++) begin uart_rx = b[i]; #(BIT_NS); end
        uart_rx = 1; #(BIT_NS);
    endtask

    // PC receiver: decode uart_tx (sample mid-bit)
    initial begin
        logic [7:0] r;
        wait (sys_rst_n);
        forever begin
            @(negedge uart_tx);
            #(BIT_NS/2);
            if (uart_tx !== 0) begin errors++; $display("FAIL: bad start bit"); end
            for (int i = 0; i < 8; i++) begin #(BIT_NS); r[i] = uart_tx; end
            #(BIT_NS);
            if (uart_tx !== 1) begin errors++; $display("FAIL: bad stop bit"); end
            got++;
            if (exp_q.size() == 0) begin errors++; $display("FAIL: unexpected echo %02h", r); end
            else begin
                logic [7:0] e; e = exp_q.pop_front();
                if (r !== e) begin errors++; $display("FAIL: echoed %02h, expected %02h", r, e); end
            end
        end
    end

    // count heartbeat toggles
    logic led0_d;
    always @(posedge sys_clk) begin led0_d <= led[0]; if (sys_rst_n && led0_d !== led[0]) hb_toggles++; end

    initial begin
        logic [1:0] led1_start;
        #100;
        if (led !== 2'b11) begin errors++; $display("FAIL: LEDs should be off (11) in reset, got %b", led); end
        sys_rst_n = 1;
        #(3*BIT_NS);
        led1_start = led[1];
        pc_send("H"); pc_send("i"); pc_send("!");
        for (int n = 0; n < 50; n++) begin pc_send($urandom); #($urandom_range(0, 2) * BIT_NS); end
        #(12*BIT_NS);
        if (exp_q.size() != 0 || got != sent) begin errors++; $display("FAIL: sent %0d, echoed %0d", sent, got); end
        // 53 bytes -> led[1] toggled 53 times -> odd -> different from start
        if (led[1] === led1_start) begin errors++; $display("FAIL: led[1] did not toggle an odd number of times"); end
        $display("heartbeat toggles: %0d (expected about %0d)", hb_toggles, int'($time / (CLK_HZ/2 * 10.0)));
        if (hb_toggles == 0) begin errors++; $display("FAIL: heartbeat never toggled"); end
        if (errors == 0) $display("PASS: %0d bytes echoed correctly, LEDs OK", got);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule