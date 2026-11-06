`timescale 1ns/1ps

// Self-checking testbench for argmax (streaming: one int32 per cycle, in_last on the final element).
//
// Reference model: for every vector, the maximum and the index of the FIRST maximum (same as
// NumPy's argmax). The expected results are queued when the vector is queued; a monitor pops
// one expected result for every out_valid and compares out_max and out_index.
//
// Also checked:
//   - timing: out_valid is high in exactly the cycle after (in_valid && in_last), and never otherwise
//   - one result per vector (count), nothing unexpected, nothing missing
//   - outputs defined (no X) after reset
//
// Phases:
//   1. directed: all negative, all equal (ties), max first / last / middle, int32 extremes,
//      single element, full WIDTH-long vectors
//   2. random vectors, back to back (no gaps)
//   3. random vectors with random gaps (in_valid low) inside and between vectors
//   4. random values from a tiny range, so ties and equal maxima are common
//
// Run:
//   iverilog -g2012 -o sim.vvp board/argmax.sv tb/tb_argmax.sv -s tb_argmax && vvp sim.vvp
//   iverilog ... -Ptb_argmax.WIDTH=4 ...        vvp sim.vvp +seed=7

module tb_argmax;
    parameter int WIDTH  = 10;
    parameter int N_RAND = 500;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic in_valid = 0, in_last = 0;
    logic signed [31:0] in_data = 0;
    logic out_valid;
    logic signed [31:0] out_max;
    logic [$clog2(WIDTH)-1:0] out_index;

    argmax #(.WIDTH(WIDTH)) dut (.*);

    int errors = 0;
    task automatic fail(input string msg);
        errors++;
        if (errors <= 15) $display("FAIL @%0t: %s", $time, msg);
    endtask

    // ---------------- driver: element queue -> DUT inputs (changes on the falling edge)
    logic signed [31:0] d_q [$];
    logic               l_q [$];
    int gap_pct = 0;                       // chance (%) of an idle cycle before each element
    always @(negedge clk) begin
        // junk on data and last while in_valid is low: must be ignored
        in_valid = 0; in_last = $urandom_range(0, 1);
        in_data  = $urandom;
        if (rst_n && d_q.size() > 0 && ($urandom_range(0, 99) >= gap_pct)) begin
            in_valid = 1;
            in_data  = d_q.pop_front();
            in_last  = l_q.pop_front();
        end
    end

    // ---------------- reference model: queue a vector and its expected result
    logic signed [31:0] em_q [$];
    int                 ei_q [$];
    int n_vec = 0;

    logic signed [31:0] v [$];             // staging vector for queue_vec()

    task automatic queue_vec();
        logic signed [31:0] m;
        int mi;
        m = v[0]; mi = 0;
        for (int i = 1; i < v.size(); i++) if (v[i] > m) begin m = v[i]; mi = i; end
        for (int i = 0; i < v.size(); i++) begin
            d_q.push_back(v[i]);
            l_q.push_back(i == v.size() - 1);
        end
        em_q.push_back(m);
        ei_q.push_back(mi);
        n_vec++;
    endtask

    // ---------------- monitor
    logic pend = 0;                        // (in_valid && in_last) seen at the previous edge
    int n_out = 0, n_ok = 0;
    logic signed [31:0] em;
    int ei;
    always @(posedge clk) if (rst_n) begin
        if (out_valid !== pend)
            fail($sformatf("out_valid = %b, expected %b (it must follow in_last by exactly one cycle)", out_valid, pend));
        if (out_valid === 1'b1) begin
            n_out++;
            if (em_q.size() == 0) fail("result with no vector queued");
            else begin
                em = em_q.pop_front(); ei = ei_q.pop_front();
                if (out_max !== em)            fail($sformatf("vector %0d: max = %0d, expected %0d", n_out - 1, out_max, em));
                else if (out_index !== ei[$clog2(WIDTH)-1:0])
                                               fail($sformatf("vector %0d: index = %0d, expected %0d (max %0d)", n_out - 1, out_index, ei, em));
                else n_ok++;
            end
        end
        pend = in_valid && in_last;
    end

    // ---------------- helpers
    function automatic logic signed [31:0] rnd(input int mode);
        case (mode)
            0: return $urandom;                                  // full range
            1: return $signed(32'($urandom_range(0, 4))) - 2;    // tiny range: ties everywhere
            default: begin
                case ($urandom_range(0, 5))
                    0: return 32'sh7FFFFFFF;
                    1: return 32'sh80000000;
                    2: return 0;
                    3: return -1;
                    default: return $urandom;
                endcase
            end
        endcase
    endfunction

    task automatic rand_vec(input int len, input int mode);
        v = {};
        for (int i = 0; i < len; i++) v.push_back(rnd(mode));
        queue_vec();
    endtask

    task automatic drain(input string label);
        int t = 0;
        while ((d_q.size() > 0 || em_q.size() > 0) && t < 200000) begin @(negedge clk); t++; end
        repeat (5) @(negedge clk);
        if (d_q.size() || em_q.size())
            fail($sformatf("[%s] stuck: %0d elements unsent, %0d results missing", label, d_q.size(), em_q.size()));
        else if (n_out != n_vec)
            fail($sformatf("[%s] %0d results for %0d vectors", label, n_out, n_vec));
        else
            $display("  %-34s ok: %0d vectors so far", label, n_vec);
        if (errors > 0) begin $display("FAIL: stopping after phase [%s], %0d errors", label, errors); $finish; end
    endtask

    int seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_argmax: WIDTH = %0d, seed = %0d", WIDTH, seed);
        void'($urandom(seed));

        repeat (3) @(negedge clk);
        if (out_valid !== 1'b0) fail("out_valid not 0 during reset");
        rst_n = 1;
        repeat (3) @(negedge clk);

        // 1. directed
        gap_pct = 0;
        v = {}; for (int i = 0; i < WIDTH; i++) v.push_back(-100 - i);        queue_vec();   // all negative, max first
        v = {}; for (int i = 0; i < WIDTH; i++) v.push_back(-100 + i);        queue_vec();   // all negative, max last
        v = {}; for (int i = 0; i < WIDTH; i++) v.push_back(7);               queue_vec();   // all equal -> index 0
        v = {}; for (int i = 0; i < WIDTH; i++) v.push_back(i == WIDTH/2 ? 5 : -5); queue_vec(); // max in the middle
        v = {}; for (int i = 0; i < WIDTH; i++) v.push_back((i % 2) ? 9 : 3); queue_vec();   // tie later: first wins
        v = {}; for (int i = 0; i < WIDTH; i++) v.push_back(i == 0 ? 32'sh7FFFFFFF : 32'sh80000000); queue_vec();
        v = {}; for (int i = 0; i < WIDTH; i++) v.push_back(i == WIDTH-1 ? 32'sh80000001 : 32'sh80000000); queue_vec();
        v = {}; v.push_back(-3);                                              queue_vec();   // single element
        v = {}; v.push_back(32'sh80000000);                                   queue_vec();
        v = {}; for (int i = 0; i < WIDTH; i++) v.push_back(0);               queue_vec();   // all zero
        drain("directed");

        // 2. random, back to back
        for (int n = 0; n < N_RAND; n++) rand_vec($urandom_range(1, WIDTH), n % 3 == 2 ? 2 : 0);
        drain("random, back to back");

        // 3. random with gaps
        gap_pct = 40;
        for (int n = 0; n < N_RAND; n++) rand_vec($urandom_range(1, WIDTH), n % 3 == 2 ? 2 : 0);
        drain("random, with gaps");

        // 4. ties
        gap_pct = 20;
        for (int n = 0; n < N_RAND; n++) rand_vec($urandom_range(1, WIDTH), 1);
        drain("ties (tiny value range)");

        if (errors == 0) $display("PASS: %0d vectors correct (max, first-max index, timing), WIDTH = %0d", n_ok, WIDTH);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule