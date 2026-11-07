`timescale 1ns/1ps

// Self-checking testbench for infer_core. Run from the repository root:
//   python3 tb/gen_infer_vectors.py
//   iverilog -g2012 -I ml/mem -s tb_infer_core -o t.vvp rtl/*.sv board/*.sv tb/tb_infer_core.sv && vvp -n t.vvp
//
// For every batch of 4 images it loads the input RAM through the in_we port (like frame_rx does,
// with different gap patterns), pulses start, waits for done and checks:
//   digits, done_seq, the whole hidden RAM (all 64 words), exactly one done pulse,
//   busy high during the run and low shortly after done, the cycle count, and that a second
//   start pulse in the middle of a run is ignored.
// Vectors come from tb/gen_infer_vectors.py (integer model = ml/ref_infer.py).
module tb_infer_core;
    parameter int N_BATCH = 12;
    parameter int MIN_CYCLES = 12000;     // start -> done, measured on the reference design: ~13,000
    parameter int MAX_CYCLES = 15000;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic in_we = 0;
    logic [9:0]  in_waddr = 0;
    logic [31:0] in_wdata = 0;
    logic start = 0;
    logic [6:0] start_seq = 0;
    logic busy, done;
    logic [6:0] done_seq;
    logic [3:0][3:0] digits;

    infer_core #(
        .W_FILE ("ml/mem/weights.mem"),
        .B1_FILE("ml/mem/bias1.mem"),
        .B2_FILE("ml/mem/bias2.mem")
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .in_we(in_we), .in_waddr(in_waddr), .in_wdata(in_wdata),
        .start(start), .start_seq(start_seq),
        .busy(busy), .done(done), .done_seq(done_seq), .digits(digits)
    );

    // ---- vectors
    logic [31:0] v_in  [0:N_BATCH*784-1];
    logic [31:0] v_hid [0:N_BATCH*64-1];
    logic [15:0] v_dig [0:N_BATCH-1];

    // ---- bookkeeping (module level: Icarus does not like declarations inside initial blocks)
    int errors = 0;
    int cyc = 0;                 // free running cycle counter
    int done_count = 0;          // done pulses seen since the counter was cleared
    int t_start, t_done;
    int b, k, n, i, w;
    int busy_low_in_run = 0;
    logic [31:0] exp_hid, got_hid;
    logic [3:0] exp_d;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (done) done_count <= done_count + 1;
    end

    // global watchdog
    always @(posedge clk) if (cyc > 3_000_000) begin
        $display("FAIL @%0t: watchdog, testbench is stuck", $time);
        $finish;
    end

    task automatic fail(input string msg);
        begin
            errors = errors + 1;
            if (errors <= 12) $display("FAIL @%0t: %s", $time, msg);
        end
    endtask

    // write the 784 input words of batch bb through the write port; gap_mode: 0 = one per cycle,
    // 1 = a gap of 3 cycles after every word, 2 = a gap of 1 to 4 cycles, pseudo random
    task automatic load_input(input int bb, input int gap_mode);
        int g;
        begin
            for (k = 0; k < 784; k++) begin
                @(negedge clk);
                in_we <= 1; in_waddr <= k[9:0]; in_wdata <= v_in[bb*784 + k];
                @(negedge clk);
                in_we <= 0; in_waddr <= 10'($urandom); in_wdata <= 32'($urandom);   // junk while we is low
                g = (gap_mode == 0) ? 0 : (gap_mode == 1) ? 3 : (1 + ($urandom % 4));
                repeat (g) @(negedge clk);
            end
        end
    endtask

    // pulse start for one cycle
    task automatic pulse_start(input logic [6:0] s);
        begin
            @(negedge clk);
            start <= 1; start_seq <= s;
            @(negedge clk);
            start <= 0; start_seq <= 7'($urandom);
        end
    endtask

    // run batch bb: load, start, (optionally poke a second start), wait for done, check everything
    task automatic run_batch(input int bb, input int gap_mode, input bit poke);
        logic [6:0] s;
        int timeout;
        begin
            s = 7'((bb * 37 + 5) % 128);
            load_input(bb, gap_mode);
            repeat (3) @(negedge clk);
            if (busy !== 1'b0) fail($sformatf("batch %0d: busy high before start", bb));

            done_count = 0;
            t_start = cyc;
            pulse_start(s);
            @(negedge clk);
            if (busy !== 1'b1) fail($sformatf("batch %0d: busy not high right after start", bb));

            if (poke) begin
                repeat (500) @(negedge clk);
                start <= 1; start_seq <= 7'd99;      // must be ignored (busy)
                @(negedge clk);
                start <= 0;
            end

            timeout = 0;
            while (done !== 1'b1 && timeout < MAX_CYCLES + 2000) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (done !== 1'b1 && busy !== 1'b1) busy_low_in_run = busy_low_in_run + 1;
            end
            t_done = cyc;
            if (done !== 1'b1) begin
                fail($sformatf("batch %0d: no done after %0d cycles", bb, timeout));
            end else begin
                if (t_done - t_start < MIN_CYCLES || t_done - t_start > MAX_CYCLES)
                    fail($sformatf("batch %0d: %0d cycles from start to done (expected %0d..%0d)",
                                   bb, t_done - t_start, MIN_CYCLES, MAX_CYCLES));
                if (done_seq !== s)
                    fail($sformatf("batch %0d: done_seq %0d, expected %0d", bb, done_seq, s));
                for (i = 0; i < 4; i++) begin
                    exp_d = v_dig[bb][4*i +: 4];
                    if (digits[i] !== exp_d)
                        fail($sformatf("batch %0d image %0d: digit %0d, expected %0d", bb, i, digits[i], exp_d));
                end
                for (n = 0; n < 64; n++) begin
                    exp_hid = v_hid[bb*64 + n];
                    got_hid = dut.u_hid_ram.mem[n];
                    if (got_hid !== exp_hid)
                        fail($sformatf("batch %0d: hidden word %0d is %08x, expected %08x", bb, n, got_hid, exp_hid));
                end
            end
            repeat (3) @(negedge clk);
            if (busy !== 1'b0) fail($sformatf("batch %0d: busy still high 3 cycles after done", bb));
            repeat (200) @(negedge clk);           // anything late or repeated shows up here
            if (done_count !== 1) fail($sformatf("batch %0d: %0d done pulses, expected exactly 1", bb, done_count));
            if (busy !== 1'b0) fail($sformatf("batch %0d: busy high after the run", bb));
        end
    endtask

    initial begin
        $readmemh("tb/vectors/infer_in.hex",  v_in);
        $readmemh("tb/vectors/infer_hid.hex", v_hid);
        $readmemh("tb/vectors/infer_dig.hex", v_dig);
        if (^v_in[N_BATCH*784-1] === 1'bx || ^v_hid[N_BATCH*64-1] === 1'bx || ^v_dig[N_BATCH-1] === 1'bx) begin
            $display("FAIL: vector files shorter than N_BATCH = %0d (run tb/gen_infer_vectors.py --n %0d)", N_BATCH, N_BATCH);
            $finish;
        end
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (5) @(negedge clk);

        for (b = 0; b < N_BATCH; b++)
            run_batch(b, b % 3, (b == 3 || b == 7));

        // the same batch twice in a row: nothing may leak from one run into the next
        run_batch(5, 0, 0);
        run_batch(5, 0, 0);
        // and a different one right after it
        run_batch(2, 1, 0);

        if (busy_low_in_run != 0) fail($sformatf("busy dropped %0d times in the middle of a run", busy_low_in_run));

        if (errors == 0)
            $display("PASS: %0d batches (%0d images), digits + 64 hidden words each, %0d cycles per batch", N_BATCH + 3, 4 * (N_BATCH + 3), t_done - t_start);
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule