`timescale 1ns/1ps

// System testbench for infer_board_top (v3), through the UART pins. Run from the repo root:
//   python3 ml/gen_mem.py && python3 tb/gen_infer_vectors.py
//   iverilog -g2012 -I ml/mem -s tb_infer_board_top -o t.vvp rtl/*.sv board/*.sv tb/tb_infer_board_top.sv && vvp -n t.vvp
//
// The "PC" sends frames [A6][seq][3136 pixel bytes][checksum] built from tb/vectors/infer_in.hex
// and waits for each reply before the next frame (stop and wait). Scenarios: junk before the
// first frame, good frames, a bad checksum, a frame cut short and followed straight away by a
// new START, a cut frame followed by junk, seq 0 and 127. Checked: every reply byte
// ([A6][seq][d0..d3] or [E6][seq]) with good start/stop bits, nothing extra, led[1] toggles
// once per reply, the heartbeat led[0] toggles.
module tb_infer_board_top;
    parameter int N_BATCH = 12;          // batches in the vector files

    localparam int  BAUD   = 100;
    localparam int  CLK_HZ = 16 * BAUD;  // 16 clocks per bit keeps the simulation short
    localparam real BIT_NS = 16 * 10.0;

    logic sys_clk = 0, sys_rst_n = 0, uart_rx = 1;
    logic uart_tx;
    logic [1:0] led;

    infer_board_top #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD),
        .W_FILE("ml/mem/weights.mem"), .B1_FILE("ml/mem/bias1.mem"), .B2_FILE("ml/mem/bias2.mem")
    ) dut (.*);
    always #5 sys_clk = ~sys_clk;

    logic [31:0] v_in  [0:N_BATCH*784-1];
    logic [15:0] v_dig [0:N_BATCH-1];

    int errors = 0;
    task automatic fail(input string msg);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("FAIL @%0t: %s", $time, msg);
        end
    endtask

    // ---------------- PC transmitter
    task automatic pc_send(input logic [7:0] b);
        int bi;
        begin
            uart_rx = 0;                                       #(BIT_NS);
            for (bi = 0; bi < 8; bi++) begin uart_rx = b[bi]; #(BIT_NS); end
            uart_rx = 1;                                       #(BIT_NS);
        end
    endtask

    // ---------------- expected and received reply bytes
    logic [7:0] exp_b [0:1023];
    logic [7:0] got_b [0:1023];
    int n_exp = 0, n_got = 0, n_replies = 0;
    logic [7:0] r;
    int ri;

    initial begin
        wait (sys_rst_n);
        forever begin
            @(negedge uart_tx);
            #(BIT_NS / 2);
            if (uart_tx !== 0) fail("reply: bad start bit");
            for (ri = 0; ri < 8; ri++) begin #(BIT_NS); r[ri] = uart_tx; end
            #(BIT_NS);
            if (uart_tx !== 1) fail("reply: bad stop bit");
            got_b[n_got] = r;
            if (n_got >= n_exp) fail($sformatf("unexpected reply byte 0x%02h", r));
            else if (r !== exp_b[n_got]) fail($sformatf("reply byte %0d = 0x%02h, expected 0x%02h", n_got, r, exp_b[n_got]));
            n_got = n_got + 1;
        end
    end

    task automatic expect_ok(input int b, input logic [6:0] s);
        int d;
        begin
            exp_b[n_exp] = 8'hA6; exp_b[n_exp+1] = {1'b0, s};
            for (d = 0; d < 4; d++) exp_b[n_exp+2+d] = {4'b0, v_dig[b][4*d +: 4]};
            n_exp = n_exp + 6; n_replies = n_replies + 1;
        end
    endtask

    task automatic expect_err(input logic [6:0] s);
        begin
            exp_b[n_exp] = 8'hE6; exp_b[n_exp+1] = {1'b0, s};
            n_exp = n_exp + 2; n_replies = n_replies + 1;
        end
    endtask

    // send a frame of batch b. cut > 0: stop after that many payload bytes (no checksum).
    // bad = 1: send checksum + 1.
    task automatic send_frame(input int b, input logic [6:0] s, input int cut, input bit bad);
        int k, i, nbytes;
        logic [6:0] sum;
        logic [7:0] px;
        begin
            sum = 0; nbytes = 0;
            pc_send(8'hA6);
            pc_send({1'b0, s});
            for (k = 0; k < 784; k++) for (i = 0; i < 4; i++) begin
                if (cut == 0 || nbytes < cut) begin
                    px = v_in[b*784 + k][8*i +: 8];
                    pc_send(px);
                    sum = sum + px[6:0];
                    nbytes = nbytes + 1;
                end
            end
            if (cut == 0) pc_send({1'b0, bad ? 7'(sum + 1) : sum});
        end
    endtask

    // stop and wait: until every expected byte has arrived (plus a little), or time out
    task automatic wait_replies;
        int t;
        begin
            t = 0;
            while (n_got < n_exp && t < 400000) begin @(posedge sys_clk); t = t + 1; end
            if (n_got < n_exp) fail($sformatf("timed out: %0d of %0d reply bytes", n_got, n_exp));
            #(20 * BIT_NS);
        end
    endtask

    // ---------------- LED monitor
    int led1_toggles = 0, led0_toggles = 0;
    logic [1:0] led_prev;
    always @(posedge sys_clk) begin
        if (sys_rst_n && led_prev !== led) begin
            if (led_prev[1] !== led[1]) led1_toggles = led1_toggles + 1;
            if (led_prev[0] !== led[0]) led0_toggles = led0_toggles + 1;
        end
        led_prev <= led;
    end

    initial begin
        $readmemh("tb/vectors/infer_in.hex",  v_in);
        $readmemh("tb/vectors/infer_dig.hex", v_dig);
        if (^v_in[N_BATCH*784-1] === 1'bx || ^v_dig[N_BATCH-1] === 1'bx) begin
            $display("FAIL: vector files shorter than N_BATCH = %0d", N_BATCH);
            $finish;
        end
        #200;
        sys_rst_n = 1;
        #(5 * BIT_NS);
        if ($isunknown(led)) fail($sformatf("LEDs undefined after reset: %b", led));

        // 1. junk before any frame: ignored, no reply
        pc_send(8'h12); pc_send(8'h7F); pc_send(8'hFF); pc_send(8'h00);
        // 2. a good frame
        expect_ok(0, 7'd10);  send_frame(0, 7'd10, 0, 0);  wait_replies();
        // 3. bad checksum -> error reply, no compute
        expect_err(7'd11);    send_frame(1, 7'd11, 0, 1);  wait_replies();
        // 4. good frame (all-negative logits batch)
        expect_ok(4, 7'd12);  send_frame(4, 7'd12, 0, 0);  wait_replies();
        // 5. a frame cut after 1000 payload bytes, then straight away a new frame: only that one answers
        expect_ok(2, 7'd14);  send_frame(2, 7'd13, 1000, 0);  send_frame(2, 7'd14, 0, 0);  wait_replies();
        // 6. a cut frame, then junk, then a good frame with seq 127
        send_frame(3, 7'd15, 7, 0);  pc_send(8'h05); pc_send(8'hC0); pc_send(8'h22);
        expect_ok(7, 7'd127); send_frame(7, 7'd127, 0, 0);  wait_replies();
        // 7. seq 0
        expect_ok(9, 7'd0);   send_frame(9, 7'd0, 0, 0);    wait_replies();

        #(200 * BIT_NS);
        if (n_got != n_exp) fail($sformatf("got %0d reply bytes, expected %0d", n_got, n_exp));
        if (led1_toggles != n_replies) fail($sformatf("led[1] toggled %0d times for %0d replies", led1_toggles, n_replies));
        if (led0_toggles == 0) fail("heartbeat led[0] never toggled");

        if (errors == 0)
            $display("PASS: %0d replies (%0d bytes) correct through the pins: good frames, bad checksum, cut frames, junk",
                     n_replies, n_got);
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule