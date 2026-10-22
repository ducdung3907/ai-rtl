`timescale 1ns/1ps

// Self-checking testbench for complete_sa (skew + N x N systolic array).
//
// Computes C = A x B, where A is N x K and B is K x N. The testbench feeds the
// matrices UNSKEWED: on each input cycle it sends one column of A and one row of B.
//   a_col[i] = A[i][k]     (column k of A)
//   b_row[j] = B[k][j]     (row k of B)
//   start    = 1 on the first column of each matrix, valid = 1 on every real column
// All skewing is done by the hardware.
//
// Tests:
//   1. Directed:     identity, K = 1, all -128, -128 x 127, zeros after data
//   2. Bubbles:      random idle cycles (valid = 0, junk data) between columns.
//                    Results must not change: valid travels with the data.
//   3. Back-to-back: two matrix pairs streamed with no gap; the second must be correct
//   4. Random:       random K (1 .. K_MAX), sometimes with bubbles
//   After every test the results are also checked again after a few idle cycles (hold).
//
// Run:
//   iverilog -g2012 -o sim.vvp rtl/mac8.sv rtl/pe8.sv rtl/systolic_array.sv \
//            rtl/skew.sv rtl/complete_sa.sv tb/tb_complete_sa.sv && vvp sim.vvp
//   iverilog -g2012 -Ptb_complete_sa.N=8 ...    (other sizes)
//   vvp sim.vvp +seed=42                        (other random sequence)

module tb_complete_sa;

    parameter int N            = 4;    // array size
    parameter int K_MAX        = 16;   // longest inner dimension tested
    parameter int RANDOM_TESTS = 500;

    // ------------------------------------------------------------------
    // Signals
    // ------------------------------------------------------------------
    logic clk = 0, rst_n = 0;

    logic [N-1:0][7:0] a_col = '0, b_row = '0;
    logic              valid = 0, start = 0;

    logic [N*N*32-1:0] acc_flat;   // all N*N results; matches [N-1:0][N-1:0][31:0]

    // ------------------------------------------------------------------
    // DUT and clock
    // ------------------------------------------------------------------
    complete_sa #(.N(N)) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .a_col (a_col),
        .b_row (b_row),
        .valid (valid),
        .start (start),
        .acc   (acc_flat)
    );

    always #5 clk = ~clk;   // 10 ns period

    // Result C[i][j] as a signed number
    function automatic int result(input int i, input int j);
        return $signed(acc_flat[(i*N + j)*32 +: 32]);
    endfunction

    // ------------------------------------------------------------------
    // Test data and reference model
    // ------------------------------------------------------------------
    // Sized 2*K_MAX so back-to-back tests can hold two matrix pairs in a row
    logic signed [7:0] A [N][2*K_MAX];
    logic signed [7:0] B [2*K_MAX][N];
    int                C [N][N];
    int                K;            // total number of columns streamed in this test
    int                K2_START;     // back-to-back only: first column of the second pair (0 = off)
    int                BUBBLE_PCT;   // chance (%) of an idle cycle before each column

    int errors  = 0;
    int tests   = 0;
    int bubbles = 0;
    int i, j, k;                     // declared once, assigned in loops (Icarus quirk)

    task automatic compute_expected();
        for (i = 0; i < N; i++)
            for (j = 0; j < N; j++) begin
                C[i][j] = 0;
                for (k = K2_START; k < K; k++)     // back-to-back: only the second pair counts
                    C[i][j] = C[i][j] + int'(A[i][k]) * int'(B[k][j]);
            end
    endtask

    task automatic randomize_AB();
        for (i = 0; i < N; i++)
            for (k = 0; k < K; k++)
                A[i][k] = $urandom;
        for (k = 0; k < K; k++)
            for (j = 0; j < N; j++)
                B[k][j] = $urandom;
    endtask

    task automatic fill_AB(input int a_val, input int b_val);
        for (i = 0; i < N; i++)
            for (k = 0; k < K; k++)
                A[i][k] = a_val;
        for (k = 0; k < K; k++)
            for (j = 0; j < N; j++)
                B[k][j] = b_val;
    endtask

    // ------------------------------------------------------------------
    // Feed the matrices unskewed: one column of A and one row of B per cycle.
    // With BUBBLE_PCT > 0, random idle cycles are inserted between columns.
    // During a bubble the data inputs carry random junk, which must be ignored.
    // ------------------------------------------------------------------
    task automatic feed_matrices();
        for (k = 0; k < K; k++) begin
            // optional bubble (never before the first column)
            while (k > 0 && $urandom_range(1, 100) <= BUBBLE_PCT) begin
                @(negedge clk);
                for (i = 0; i < N; i++) begin
                    a_col[i] = $urandom;
                    b_row[i] = $urandom;
                end
                valid = 0;
                start = 0;
                bubbles++;
            end

            @(negedge clk);
            for (i = 0; i < N; i++) a_col[i] = A[i][k];
            for (j = 0; j < N; j++) b_row[j] = B[k][j];
            valid = 1;
            start = (k == 0) || (K2_START > 0 && k == K2_START);
        end

        // back to idle
        @(negedge clk);
        a_col = '0; b_row = '0; valid = 0; start = 0;
    endtask

    task automatic compare(input string label);
        for (i = 0; i < N; i++)
            for (j = 0; j < N; j++)
                if (result(i, j) !== C[i][j]) begin
                    errors++;
                    if (errors <= 10)
                        $display("FAIL [%s] N=%0d K=%0d  C[%0d][%0d] = %0d, expected %0d",
                                 label, N, K, i, j, result(i, j), C[i][j]);
                end
    endtask

    // ------------------------------------------------------------------
    // One full test
    // ------------------------------------------------------------------
    task automatic run_test(input string label);
        compute_expected();
        feed_matrices();

        // The last column needs N-1 cycles in the skew, N-1 more inside the array
        // to reach PE(N-1,N-1), and 1 to accumulate. Wait a little extra.
        repeat (2*N + 1) @(negedge clk);
        compare(label);

        // With inputs idle, results must hold
        repeat (3) @(negedge clk);
        compare({label, " (hold)"});

        tests++;
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    int seed;

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_complete_sa: N = %0d, K_MAX = %0d, seed = %0d", N, K_MAX, seed);
        void'($urandom(seed));

        K2_START   = 0;
        BUBBLE_PCT = 0;

        // Reset
        #12 rst_n = 1;

        // --- 1. Directed tests ------------------------------------------

        // Identity: A x I = A   (K = N)
        K = N;
        randomize_AB();
        for (k = 0; k < K; k++)
            for (j = 0; j < N; j++)
                B[k][j] = (k == j) ? 1 : 0;
        run_test("identity");

        // K = 1: each result is a single product
        K = 1;
        randomize_AB();
        run_test("K = 1");

        // Largest results: every product is (-128) x (-128)
        K = K_MAX;
        fill_AB(-128, -128);
        run_test("all -128");

        // Most negative results: every product is (-128) x 127
        K = K_MAX;
        fill_AB(-128, 127);
        run_test("-128 x 127");

        // Zeros right after data: start must reset every PE
        K = N;
        fill_AB(0, 77);
        run_test("zeros after data");

        // --- 2. Bubbles: idle cycles with junk data between columns -------
        BUBBLE_PCT = 40;
        for (int t = 0; t < 50; t++) begin
            K = $urandom_range(1, K_MAX);
            randomize_AB();
            run_test($sformatf("bubbles %0d", t));
        end
        BUBBLE_PCT = 0;

        // --- 3. Back-to-back: two pairs with no gap ---------------------
        for (int t = 0; t < 50; t++) begin
            K2_START = $urandom_range(1, K_MAX);           // length of the first pair
            K        = K2_START + $urandom_range(1, K_MAX);
            randomize_AB();
            run_test($sformatf("back-to-back %0d", t));
        end
        K2_START = 0;

        // --- 4. Random: random K, bubbles in a quarter of the tests ------
        for (int t = 0; t < RANDOM_TESTS; t++) begin
            K          = $urandom_range(1, K_MAX);
            BUBBLE_PCT = ($urandom_range(0, 3) == 0) ? 25 : 0;
            randomize_AB();
            run_test($sformatf("random %0d", t));
        end

        // --- Summary ----------------------------------------------------
        if (errors == 0) $display("PASS: all %0d matrix multiplications correct (N = %0d, %0d bubble cycles)",
                                  tests, N, bubbles);
        else             $display("FAIL: %0d wrong results in %0d tests (N = %0d)", errors, tests, N);
        $finish;
    end

endmodule