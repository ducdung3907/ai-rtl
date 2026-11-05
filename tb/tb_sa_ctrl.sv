`timescale 1ns/1ps
 
// Testbench for the pipelined job path (no UART):
//
//   bytes -> sync_fifo -> sa_ctrl (v2) -> complete_sa -> res_buf -> reply bytes
//
// A producer pushes request bytes into the FIFO's write side (respecting full),
// with random gaps or back to back. A consumer takes reply bytes from res_buf with
// a random out_ready (fast or slow). Every reply byte is compared, in order, with
// a queue of expected bytes built from A x B when the job was queued.
//
// Phases:
//   1. directed jobs with gaps: K = 1, N, 7, 256
//   2. random jobs back to back, fast consumer  (request of job n+1 overlaps reply n)
//   3. random jobs back to back, slow consumer  (forces the HANDOFF stall)
//   4. junk and K = 0 headers mixed between back-to-back jobs
//
// Also checked:
//   - exactly one capture per job, job_done == capture
//   - start only on the first step of a job, last only on step K
//   - start/last never without valid
//   - the FIFO never overflows; at the end everything is idle and empty
//
// Run:
//   iverilog -g2012 -o sim.vvp rtl/mac.sv rtl/pe.sv rtl/saNxN.sv rtl/skew.sv rtl/sa_top.sv \
//       board/sync_fifo.sv board/res_buf.sv board/sa_ctrl.sv tb/tb_sa_ctrl.sv -s tb_sa_ctrl
//   vvp sim.vvp
//   iverilog ... -Ptb_sa_ctrl.N=8 ...     vvp sim.vvp +seed=7
 
module tb_sa_ctrl;
    parameter int N          = 4;
    parameter int MAC_LAT    = 2;
    parameter int FIFO_DEPTH = 16;     // small on purpose: the FIFO fills and full matters
    parameter int N_RAND     = 30;
 
    localparam int MAX_K = 256;
 
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
 
    // FIFO write side (driven by the producer)
    logic       wr_valid = 0;
    logic [7:0] wr_data  = 0;
    logic       full, overflow;
    logic [$clog2(FIFO_DEPTH+1)-1:0] count;
 
    // FIFO -> sa_ctrl
    logic       rd_valid, rd_ready;
    logic [7:0] rd_data;
 
    // sa_ctrl <-> complete_sa
    logic [N-1:0][7:0] a_col, b_row;
    logic valid, start, last, done;
    logic [N-1:0][N-1:0][31:0] acc;
 
    // sa_ctrl <-> res_buf
    logic capture, res_busy, job_done, ctrl_busy;
    logic [7:0] out_data;
    logic out_valid, out_ready = 0;
 
    sync_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_fifo (.*);
    sa_ctrl #(.N(N)) dut (.*);
    complete_sa #(.N(N), .MAC_LAT(MAC_LAT)) u_sa (.*);
    res_buf #(.N(N)) u_res (.*, .busy(res_busy));
 
    int errors = 0;
    task automatic fail(input string msg);
        errors++;
        if (errors <= 15) $display("FAIL @%0t: %s", $time, msg);
    endtask
 
    // ---------------- producer: send_q -> FIFO write side
    logic [7:0] send_q [$];
    int  gap_max = 0;          // 0 = back to back
    int  gap_left = 0;
    always @(negedge clk) begin
        wr_valid = 0;
        if (rst_n) begin
            if (gap_left > 0) gap_left--;
            else if (send_q.size() > 0 && !full) begin
                wr_data  = send_q.pop_front();
                wr_valid = 1;
                gap_left = (gap_max > 0) ? $urandom_range(0, gap_max) : 0;
            end
        end
    end
 
    // ---------------- consumer: random out_ready, check every byte
    logic [7:0] exp_q [$];
    int ready_pct = 75;
    int bytes_ok = 0;
    always @(negedge clk) out_ready = ($urandom_range(0, 99) < ready_pct);
    always @(posedge clk) if (rst_n && out_valid && out_ready) begin
        if (exp_q.size() == 0) fail($sformatf("unexpected reply byte 0x%02h", out_data));
        else begin
            logic [7:0] e;
            e = exp_q.pop_front();
            if (out_data !== e) fail($sformatf("reply byte = 0x%02h, expected 0x%02h (%0d bytes ok so far)", out_data, e, bytes_ok));
            else bytes_ok++;
        end
    end
 
    // ---------------- array-side monitor
    int k_q [$];               // K of each queued real job, in order
    int step = 0, n_capture = 0, n_jobs = 0, stall_cycles = 0;
    always @(posedge clk) if (rst_n) begin
        if ((start || last) && !valid) fail("start or last without valid");
        if (job_done !== capture) fail("job_done != capture");
        if (capture) n_capture++;
        if (dut.state == dut.HANDOFF && res_busy) stall_cycles++;
        if (overflow) fail("FIFO overflow");
        if (valid) begin
            if (k_q.size() == 0) fail("valid with no job queued");
            else begin
                step++;
                if (start !== (step == 1))       fail($sformatf("start=%b on step %0d", start, step));
                if (last  !== (step == k_q[0]))  fail($sformatf("last=%b on step %0d of K=%0d", last, step, k_q[0]));
                if (step == k_q[0]) begin void'(k_q.pop_front()); step = 0; end
            end
        end
    end
 
    // ---------------- job builder
    function automatic logic signed [7:0] rv();
        case ($urandom_range(0, 9))
            0: return -128;
            1: return 127;
            2: return 0;
            default: return $urandom;
        endcase
    endfunction
 
    logic signed [7:0] A [N][MAX_K];
    logic signed [7:0] B [MAX_K][N];
 
    task automatic queue_job(input int K);
        logic signed [31:0] c;
        for (int i = 0; i < N; i++) for (int k = 0; k < K; k++) A[i][k] = rv();
        for (int k = 0; k < K; k++) for (int j = 0; j < N; j++) B[k][j] = rv();
        // expected reply: row-major, low byte first
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) begin
            c = 0;
            for (int k = 0; k < K; k++) c += 32'($signed(A[i][k])) * 32'($signed(B[k][j]));
            for (int b = 0; b < 4; b++) exp_q.push_back(c[8*b +: 8]);
        end
        k_q.push_back(K);
        n_jobs++;
        send_q.push_back(8'hA5);
        send_q.push_back(K[7:0]);
        send_q.push_back(K[15:8]);
        for (int k = 0; k < K; k++) begin
            for (int i = 0; i < N; i++) send_q.push_back(A[i][k]);
            for (int j = 0; j < N; j++) send_q.push_back(B[k][j]);
        end
    endtask
 
    task automatic queue_junk();
        int n = $urandom_range(1, 4);
        repeat (n) begin
            logic [7:0] j;
            do j = $urandom; while (j == 8'hA5);
            send_q.push_back(j);
        end
    endtask
 
    task automatic queue_k0();
        send_q.push_back(8'hA5); send_q.push_back(8'h00); send_q.push_back(8'h00);
    endtask
 
    task automatic drain(input string label);
        int t = 0;
        while ((send_q.size() > 0 || exp_q.size() > 0 || ctrl_busy || res_busy) && t < 2_000_000) begin
            @(negedge clk); t++;
        end
        repeat (20) @(negedge clk);
        if (send_q.size() || exp_q.size() || ctrl_busy || res_busy)
            fail($sformatf("[%s] stuck: %0d bytes unsent, %0d reply bytes missing, ctrl_busy=%b res_busy=%b",
                           label, send_q.size(), exp_q.size(), ctrl_busy, res_busy));
        else if (n_capture != n_jobs)
            fail($sformatf("[%s] %0d captures for %0d jobs", label, n_capture, n_jobs));
        else
            $display("  %-34s ok: %0d jobs so far, %0d HANDOFF stall cycles", label, n_jobs, stall_cycles);
        if (errors > 0) begin
            $display("FAIL: stopping after phase [%s], %0d errors", label, errors);
            $finish;
        end
    endtask
 
    int seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_sa_ctrl: N = %0d, MAC_LAT = %0d, FIFO_DEPTH = %0d, seed = %0d", N, MAC_LAT, FIFO_DEPTH, seed);
        void'($urandom(seed));
 
        repeat (3) @(negedge clk);
        rst_n = 1;
        repeat (3) @(negedge clk);
 
        // 1. directed, with gaps
        gap_max = 6; ready_pct = 75;
        queue_junk(); drain("junk only (no reply)");
        queue_k0();   drain("K = 0 (no reply)");
        queue_job(1);   drain("K = 1");
        queue_job(N);   drain("K = N");
        queue_job(7);   drain("K = 7");
        queue_job(256); drain("K = 256");
 
        // 2. back to back, fast consumer
        gap_max = 0; ready_pct = 100;
        for (int n = 0; n < N_RAND; n++) queue_job($urandom_range(1, 12));
        drain("back to back, fast consumer");
 
        // 3. back to back, slow consumer -> HANDOFF stalls
        ready_pct = 10;
        for (int n = 0; n < N_RAND; n++) queue_job($urandom_range(1, 6));
        drain("back to back, slow consumer");
 
        // 4. junk and K = 0 between back-to-back jobs
        ready_pct = 60;
        for (int n = 0; n < N_RAND; n++) begin
            case ($urandom_range(0, 3))
                0: queue_junk();
                1: queue_k0();
                default: ;
            endcase
            queue_job($urandom_range(1, 20));
        end
        drain("mixed junk / K = 0 / jobs");
 
        if (stall_cycles == 0) fail("HANDOFF stall never exercised");
        if (errors == 0) $display("PASS: %0d jobs, %0d reply bytes checked (N = %0d, MAC_LAT = %0d)", n_jobs, bytes_ok, N, MAC_LAT);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule