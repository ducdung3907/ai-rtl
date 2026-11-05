`timescale 1ns/1ps
 
// System testbench for the pipelined sa_board_top (v2), through the UART pins.
//
// The "PC" works like host --window W: it keeps up to W jobs outstanding,
// sending job n+W only after the reply to job n has fully arrived. With W >= 2
// the next request streams in on uart_rx while the previous reply goes out on
// uart_tx, which is the point of v2.
//
//   PC -> uart_rx -> uart_rx -> sync_fifo -> sa_ctrl -> complete_sa -> res_buf -> uart_tx -> PC
//
// Checked: every reply equals A x B, in job order; led[1] toggles once per job;
// heartbeat led[0] toggles; LEDs defined after reset; FIFO never overflows.
//
// Run:
//   iverilog -g2012 -o sim.vvp rtl/mac.sv rtl/pe.sv rtl/saNxN.sv rtl/skew.sv rtl/sa_top.sv \
//       board/uart_rx.sv board/uart_tx.sv board/sync_fifo.sv board/res_buf.sv board/sa_ctrl.sv \
//       board/sa_board_top.sv tb/tb_sa_board_top_v2.sv -s tb_sa_board_top_v2 && vvp sim.vvp
//   iverilog ... -Ptb_sa_board_top_v2.WINDOW=1 ...         (no overlap, like v1)
//   iverilog ... -Ptb_sa_board_top_v2.PC_SPEED=1.005 ...   (PC 0.5% fast)
 
module tb_sa_board_top_v2;
    parameter int  N        = 4;
    parameter int  MAC_LAT  = 2;
    parameter real PC_SPEED = 1.0;
    parameter int  WINDOW   = 2;
    parameter int  N_JOBS   = 16;
    parameter int  MAX_K    = 12;
 
    localparam int  BAUD   = 100;
    localparam int  CLK_HZ = 16 * BAUD;                 // 16 clocks per bit
    localparam real CLK_NS = 10.0;
    localparam real BIT_NS = (CLK_HZ / BAUD) * CLK_NS / PC_SPEED;
    localparam int  NB     = 4 * N * N;                 // reply bytes per job
 
    logic sys_clk = 0, sys_rst_n = 0, uart_rx = 1;
    logic uart_tx;
    logic [1:0] led;
 
    sa_board_top #(.N(N), .MAC_LAT(MAC_LAT), .CLK_HZ(CLK_HZ), .BAUD(BAUD), .FIFO_DEPTH(64)) dut (.*);
    always #5 sys_clk = ~sys_clk;
 
    int errors = 0;
    task automatic fail(input string msg);
        errors++;
        if (errors <= 15) $display("FAIL @%0t: %s", $time, msg);
    endtask
 
    // ---------------- PC transmitter
    task automatic pc_send(input logic [7:0] b);
        uart_rx = 0;                                       #(BIT_NS);
        for (int i = 0; i < 8; i++) begin uart_rx = b[i]; #(BIT_NS); end
        uart_rx = 1;                                       #(BIT_NS);
    endtask
 
    // ---------------- expected replies (all jobs, in order) and PC receiver
    logic [7:0] exp_q [$];
    int got = 0, bytes_ok = 0;
    initial begin
        logic [7:0] r, e;
        wait (sys_rst_n);
        forever begin
            @(negedge uart_tx);
            #(BIT_NS / 2);
            if (uart_tx !== 0) fail("reply: bad start bit");
            for (int i = 0; i < 8; i++) begin #(BIT_NS); r[i] = uart_tx; end
            #(BIT_NS);
            if (uart_tx !== 1) fail("reply: bad stop bit");
            if (exp_q.size() == 0) fail($sformatf("unexpected reply byte 0x%02h", r));
            else begin
                e = exp_q.pop_front();
                if (r !== e) fail($sformatf("job %0d byte %0d = 0x%02h, expected 0x%02h", got / NB, got % NB, r, e));
                else bytes_ok++;
            end
            got++;
        end
    end
 
    // ---------------- LED monitor
    int led1_toggles = 0, led0_toggles = 0;
    logic [1:0] led_prev;
    always @(posedge sys_clk) begin
        if (sys_rst_n && led_prev !== led) begin
            if (led_prev[1] !== led[1]) led1_toggles++;
            if (led_prev[0] !== led[0]) led0_toggles++;
        end
        led_prev <= led;
        if (sys_rst_n && dut.overflow) fail("FIFO overflow");
    end
 
    // ---------------- job builder: queues the expected reply, then sends the request
    logic signed [7:0] A [N][MAX_K];
    logic signed [7:0] B [MAX_K][N];
 
    function automatic logic signed [7:0] rv();
        case ($urandom_range(0, 9))
            0: return -128;
            1: return 127;
            2: return 0;
            default: return $urandom;
        endcase
    endfunction
 
    task automatic send_job(input int K);
        logic signed [31:0] c;
        for (int i = 0; i < N; i++) for (int k = 0; k < K; k++) A[i][k] = rv();
        for (int k = 0; k < K; k++) for (int j = 0; j < N; j++) B[k][j] = rv();
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) begin
            c = 0;
            for (int k = 0; k < K; k++) c += 32'($signed(A[i][k])) * 32'($signed(B[k][j]));
            for (int b = 0; b < 4; b++) exp_q.push_back(c[8*b +: 8]);
        end
        pc_send(8'hA5);
        pc_send(K[7:0]);
        pc_send(K[15:8]);
        for (int k = 0; k < K; k++) begin
            for (int i = 0; i < N; i++) pc_send(A[i][k]);
            for (int j = 0; j < N; j++) pc_send(B[k][j]);
        end
    endtask
 
    int seed, timeout;
    realtime t0, t1;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_sa_board_top_v2: N = %0d, MAC_LAT = %0d, WINDOW = %0d, PC_SPEED = %0.3f, seed = %0d",
                 N, MAC_LAT, WINDOW, PC_SPEED, seed);
        void'($urandom(seed));
 
        #200;
        sys_rst_n = 1;
        #(5 * BIT_NS);
        if ($isunknown(led)) fail($sformatf("LEDs undefined after reset: %b", led));
 
        t0 = $realtime;
        for (int n = 0; n < N_JOBS; n++) begin
            // window: job n may go out once replies to jobs 0 .. n-WINDOW are complete
            while (got < (n - WINDOW + 1) * NB) @(posedge sys_clk);
            send_job((n == 0) ? 1 : (n == 1) ? N : $urandom_range(1, MAX_K));
        end
 
        timeout = 0;
        while (got < N_JOBS * NB && timeout < 50 * NB * int'(BIT_NS / CLK_NS)) begin
            @(posedge sys_clk); timeout++;
        end
        t1 = $realtime;
        #(3 * BIT_NS);
 
        if (got != N_JOBS * NB) fail($sformatf("got %0d reply bytes, expected %0d", got, N_JOBS * NB));
        if (led1_toggles != N_JOBS) fail($sformatf("led[1] toggled %0d times for %0d jobs", led1_toggles, N_JOBS));
        if (led0_toggles == 0) fail("heartbeat led[0] never toggled");
 
        if (errors == 0)
            $display("PASS: %0d jobs, %0d reply bytes correct through the pins, %0.0f bit times total (WINDOW = %0d)",
                     N_JOBS, bytes_ok, (t1 - t0) / BIT_NS, WINDOW);
        else
            $display("FAIL: %0d errors, %0d of %0d reply bytes correct", errors, bytes_ok, N_JOBS * NB);
        $finish;
    end
endmodule