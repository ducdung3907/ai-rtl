`timescale 1ns/1ps

// Testbench for sa_ctrl + the real complete_sa (no UART: bytes are driven
// directly as rx_data/rx_valid pulses, and replies are taken on tx_valid && tx_ready).
//
// Every job: the testbench builds random A (N x K) and B (K x N), sends
//   0xA5, K low, K high, then K steps of (column k of A, row k of B),
// with random idle cycles between bytes, then collects the 4*N*N reply bytes
// while holding tx_ready low for random stretches, and compares C with A x B.
//
// Also checked on every job:
//   - exactly K valid pulses; start only on the first, last only on the final
//   - busy is 1 from the cycle after the header until the last reply byte
//   - no reply bytes appear when no job was sent (junk, K = 0)
//
// Run:
//   iverilog -g2012 -o sim.vvp rtl/mac.sv rtl/pe.sv rtl/saNxN.sv rtl/skew.sv rtl/sa_top.sv \
//       board/sa_ctrl.sv tb/tb_sa_ctrl.sv && vvp sim.vvp
//   iverilog ... -Ptb_sa_ctrl.N=8 ...      (other array size)
//   vvp sim.vvp +seed=7

module tb_sa_ctrl;
    parameter int N       = 4;
    parameter int MAC_LAT = 2;
    parameter int N_RAND  = 20;     // random jobs after the directed ones

    logic clk = 0, rst_n = 0;
    logic [7:0] rx_data = 0;
    logic       rx_valid = 0;
    logic [7:0] tx_data;
    logic       tx_valid, tx_ready = 0;
    logic [N-1:0][7:0] a_col, b_row;
    logic valid, start, last, done, busy;
    logic [N-1:0][N-1:0][31:0] acc;

    sa_ctrl #(.N(N)) dut (.*);
    complete_sa #(.N(N), .MAC_LAT(MAC_LAT)) u_sa (
        .clk(clk), .rst_n(rst_n), .a_col(a_col), .b_row(b_row),
        .valid(valid), .start(start), .last(last), .done(done), .acc(acc)
    );

    always #5 clk = ~clk;

    int errors = 0, jobs_ok = 0;

    task automatic fail(input string msg);
        errors++;
        if (errors <= 15) $display("FAIL @%0t: %s", $time, msg);
    endtask

    // ---------------- byte sender: one rx_valid pulse, then a random gap
    int max_gap = 12;
    task automatic send_byte(input logic [7:0] b);
        @(negedge clk);
        rx_data  = b;
        rx_valid = 1;
        @(negedge clk);
        rx_valid = 0;
        rx_data  = $urandom;            // data changes after the pulse, like uart_rx's next byte
        repeat ($urandom_range(0, max_gap)) @(negedge clk);
    endtask

    // ---------------- reply collector: random tx_ready, stores bytes
    logic [7:0] reply_q [$];
    always @(negedge clk) tx_ready = ($urandom_range(0, 3) != 0);   // ready 75% of the time
    always @(posedge clk) if (rst_n && tx_valid && tx_ready) reply_q.push_back(tx_data);

    // ---------------- array-side monitor: count pulses within a job
    int n_valid = 0, n_start = 0, n_last = 0;
    int first_valid_had_start = 0, last_valid_had_last = 0, start_not_first = 0, last_not_final = 0;
    always @(posedge clk) if (rst_n) begin
        if ((start || last) && !valid) fail("start or last high without valid");
        if (valid) begin
            n_valid++;
            if (start) begin
                n_start++;
                if (n_valid != 1) start_not_first++;
            end
            if (last) n_last++;
        end
    end

    // ---------------- reference model and one job
    localparam int MAX_K = 256;
    logic signed [7:0]  A [N][MAX_K];       // fixed size: Icarus has no 2D dynamic arrays
    logic signed [7:0]  B [MAX_K][N];
    logic signed [31:0] C [N][N];

    task automatic run_job(input int K, input string label);
        int got_idx;
        int timeout;

        for (int i = 0; i < N; i++) for (int k = 0; k < K; k++) A[i][k] = rv();
        for (int k = 0; k < K; k++) for (int j = 0; j < N; j++) B[k][j] = rv();
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) begin
            C[i][j] = 0;
            for (int k = 0; k < K; k++) C[i][j] += 32'($signed(A[i][k])) * 32'($signed(B[k][j]));
        end

        n_valid = 0; n_start = 0; n_last = 0; start_not_first = 0;
        reply_q.delete();

        send_byte(8'hA5);
        send_byte(K[7:0]);
        send_byte(K[15:8]);
        for (int k = 0; k < K; k++) begin
            for (int i = 0; i < N; i++) send_byte(A[i][k]);
            for (int j = 0; j < N; j++) send_byte(B[k][j]);
        end

        // bytes arriving during compute/send must be ignored (not even a header)
        send_byte(8'hA5); send_byte(8'h01); send_byte(8'h00);

        timeout = 0;
        while (reply_q.size() < 4*N*N && timeout < 20000) begin @(negedge clk); timeout++; end
        repeat (20) @(negedge clk);

        if (reply_q.size() != 4*N*N) begin
            fail($sformatf("[%s] K=%0d: got %0d reply bytes, expected %0d (controller stuck?)", label, K, reply_q.size(), 4*N*N));
            $display("FAIL: stopping: %0d errors, %0d jobs correct", errors, jobs_ok);
            $finish;
        end else begin
            int bad = 0;
            for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) begin
                logic [31:0] g;
                got_idx = 4 * (i*N + j);
                g = {reply_q[got_idx+3], reply_q[got_idx+2], reply_q[got_idx+1], reply_q[got_idx]};
                if (g !== C[i][j]) begin
                    bad++;
                    if (bad <= 3) fail($sformatf("[%s] K=%0d: C[%0d][%0d] = %0d, expected %0d",
                                                  label, K, i, j, $signed(g), C[i][j]));
                end
            end
            if (bad == 0) jobs_ok++;
        end
        if (n_valid != K) fail($sformatf("[%s] K=%0d: %0d valid pulses", label, K, n_valid));
        if (n_start != 1 || start_not_first) fail($sformatf("[%s] K=%0d: start count %0d (must be 1, on the first step)", label, K, n_start));
        if (n_last  != 1) fail($sformatf("[%s] K=%0d: last count %0d (must be 1)", label, K, n_last));
        if (busy) fail($sformatf("[%s] busy still high after the reply", label));
    endtask

    function automatic logic signed [7:0] rv();
        case ($urandom_range(0, 9))
            0: return -128;
            1: return 127;
            2: return 0;
            default: return $urandom;
        endcase
    endfunction

    int seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_sa_ctrl: N = %0d, MAC_LAT = %0d, seed = %0d", N, MAC_LAT, seed);
        void'($urandom(seed));

        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (3) @(negedge clk);

        // junk before a header: no reply, no busy
        send_byte(8'h00); send_byte(8'hFF); send_byte(8'h5A); send_byte(8'h13);
        repeat (50) @(negedge clk);
        if (reply_q.size() != 0) fail("reply bytes after junk only");
        if (busy) fail("busy high after junk only");

        // K = 0: no job, back to waiting
        reply_q.delete();
        send_byte(8'hA5); send_byte(8'h00); send_byte(8'h00);
        repeat (50) @(negedge clk);
        if (reply_q.size() != 0) fail("reply bytes after a K = 0 job");
        if (n_valid != 0)        fail("valid pulses after a K = 0 job");
        if (busy)                fail("busy high after a K = 0 job");

        run_job(1,   "K=1, start and last together");
        run_job(N,   "K=N, square");
        run_job(7,   "K=7");
        run_job(256, "K=256, low byte 0");
        max_gap = 0;
        run_job(5,   "no gaps between bytes");
        max_gap = 12;
        for (int n = 0; n < N_RAND; n++) run_job($urandom_range(1, 40), "random");

        if (errors == 0) $display("PASS: %0d jobs correct (N = %0d, MAC_LAT = %0d)", jobs_ok, N, MAC_LAT);
        else             $display("FAIL: %0d errors, %0d jobs correct", errors, jobs_ok);
        $finish;
    end
endmodule