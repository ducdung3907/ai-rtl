    `timescale 1ns/1ps

// System testbench for sa_board_top: the whole board path in simulation.
//
// A "PC" model sends each job bit by bit into the uart_rx pin (8N1, LSB first),
// using its own bit time (PC_SPEED can make it slightly fast or slow), decodes
// the 4*N*N reply bytes from the uart_tx pin, and compares C with A x B.
//
//   PC -> uart_rx pin -> uart_rx -> sa_ctrl -> complete_sa -> sa_ctrl -> uart_tx -> uart_tx pin -> PC
//
// Also checked: led[1] toggles once per job; led[0] (heartbeat) toggles; both
// LEDs are defined (not X) after reset.
//
// The clock-to-baud ratio is small (16 clocks per bit) so the run is fast.
//
// Run:
//   iverilog -g2012 -o sim.vvp rtl/*.sv board/*.sv tb/tb_sa_board_top.sv -s tb_sa_board_top && vvp sim.vvp
//   iverilog ... -Ptb_sa_board_top.PC_SPEED=1.005 ...     (PC 0.5% fast)
//   vvp sim.vvp +seed=7

module tb_sa_board_top;
    parameter int  N        = 4;
    parameter int  MAC_LAT  = 2;
    parameter real PC_SPEED = 1.0;
    parameter int  N_JOBS   = 12;
    parameter int  MAX_K    = 12;

    localparam int  BAUD   = 100;
    localparam int  CLK_HZ = 16 * BAUD;                 // 16 clocks per bit
    localparam real CLK_NS = 10.0;                      // always #5
    localparam real BIT_NS = (CLK_HZ / BAUD) * CLK_NS / PC_SPEED;

    logic sys_clk = 0, sys_rst_n = 0, uart_rx = 1;
    logic uart_tx;
    logic [1:0] led;

    sa_board_top #(.N(N), .MAC_LAT(MAC_LAT), .CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (.*);

    always #5 sys_clk = ~sys_clk;

    int errors = 0, jobs_ok = 0;
    task automatic fail(input string msg);
        errors++;
        if (errors <= 15) $display("FAIL @%0t: %s", $time, msg);
    endtask

    // ---------------- PC transmitter: one byte, 8N1
    task automatic pc_send(input logic [7:0] b);
        uart_rx = 0;                                       #(BIT_NS);
        for (int i = 0; i < 8; i++) begin uart_rx = b[i]; #(BIT_NS); end
        uart_rx = 1;                                       #(BIT_NS);
    endtask

    // ---------------- PC receiver: decodes uart_tx into reply_q
    logic [7:0] reply_q [$];
    initial begin
        logic [7:0] r;
        wait (sys_rst_n);
        forever begin
            @(negedge uart_tx);
            #(BIT_NS / 2);
            if (uart_tx !== 0) fail("reply: bad start bit");
            for (int i = 0; i < 8; i++) begin #(BIT_NS); r[i] = uart_tx; end
            #(BIT_NS);
            if (uart_tx !== 1) fail("reply: bad stop bit");
            reply_q.push_back(r);
        end
    end

    // ---------------- LED monitors
    int led1_toggles = 0, led0_toggles = 0;
    logic [1:0] led_prev;
    always @(posedge sys_clk) begin
        if (sys_rst_n && led_prev !== led) begin
            if (led_prev[1] !== led[1]) led1_toggles++;
            if (led_prev[0] !== led[0]) led0_toggles++;
        end
        led_prev <= led;
    end

    // ---------------- reference model and one job
    logic signed [7:0]  A [N][MAX_K];
    logic signed [7:0]  B [MAX_K][N];
    logic signed [31:0] C [N][N];

    function automatic logic signed [7:0] rv();
        case ($urandom_range(0, 9))
            0: return -128;
            1: return 127;
            2: return 0;
            default: return $urandom;
        endcase
    endfunction

    task automatic run_job(input int K);
        int timeout = 0;
        int bad = 0;
        for (int i = 0; i < N; i++) for (int k = 0; k < K; k++) A[i][k] = rv();
        for (int k = 0; k < K; k++) for (int j = 0; j < N; j++) B[k][j] = rv();
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) begin
            C[i][j] = 0;
            for (int k = 0; k < K; k++) C[i][j] += 32'($signed(A[i][k])) * 32'($signed(B[k][j]));
        end
        reply_q.delete();

        pc_send(8'hA5);
        pc_send(K[7:0]);
        pc_send(K[15:8]);
        for (int k = 0; k < K; k++) begin
            for (int i = 0; i < N; i++) pc_send(A[i][k]);
            for (int j = 0; j < N; j++) pc_send(B[k][j]);
        end

        // wait for the full reply (about 4*N*N frames)
        while (reply_q.size() < 4*N*N && timeout < 4*N*N*12*int'(BIT_NS / CLK_NS) + 5000) begin
            @(posedge sys_clk); timeout++;
        end
        #(3 * BIT_NS);

        if (reply_q.size() != 4*N*N) begin
            fail($sformatf("K=%0d: got %0d reply bytes, expected %0d", K, reply_q.size(), 4*N*N));
        end else for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) begin
            int b0 = 4 * (i*N + j);
            logic [31:0] g;
            g = {reply_q[b0+3], reply_q[b0+2], reply_q[b0+1], reply_q[b0]};
            if (g !== C[i][j]) begin
                bad++;
                if (bad <= 3) fail($sformatf("K=%0d: C[%0d][%0d] = %0d, expected %0d", K, i, j, $signed(g), C[i][j]));
            end
        end
        if (bad == 0 && reply_q.size() == 4*N*N) jobs_ok++;
    endtask

    int seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_sa_board_top: N = %0d, MAC_LAT = %0d, PC_SPEED = %0.3f, seed = %0d",
                 N, MAC_LAT, PC_SPEED, seed);
        void'($urandom(seed));

        #200;
        sys_rst_n = 1;
        #(5 * BIT_NS);
        if ($isunknown(led)) fail($sformatf("LEDs undefined after reset: %b", led));

        run_job(1);
        run_job(N);
        for (int n = 2; n < N_JOBS; n++) run_job($urandom_range(1, MAX_K));

        if (led1_toggles != N_JOBS)
            fail($sformatf("led[1] toggled %0d times for %0d jobs", led1_toggles, N_JOBS));
        if (led0_toggles == 0) fail("heartbeat led[0] never toggled");

        if (errors == 0) $display("PASS: %0d jobs correct through the UART pins, LEDs OK (N = %0d, MAC_LAT = %0d)",
                                  jobs_ok, N, MAC_LAT);
        else             $display("FAIL: %0d errors, %0d of %0d jobs correct", errors, jobs_ok, N_JOBS);
        $finish;
    end
endmodule