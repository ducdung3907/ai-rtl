`timescale 1ns/1ps

// Self-checking testbench for systolic_array (N x N, output-stationary, int8 in, int32 out).
//
// Computes C = A x B, where A is N x K and B is K x N. K (the inner dimension) can be
// any length from 1 to K_MAX and changes from test to test, so the same N x N hardware
// is checked on short and long matrices.
//
// For each test it:
//   1. Picks A and B
//   2. Computes the expected C in the testbench (reference model)
//   3. Feeds A and B with skewing:
//        row i of A enters i cycles late, column j of B enters j cycles late
//   4. Waits for the array to finish and compares all N*N results
//   5. Waits a few idle cycles and checks the results did not change
//
// It also runs back-to-back tests: two matrix pairs streamed with no gap, where
// each row's second clear must reach every PE exactly when its first new product
// arrives. Only the second result is checked.
//
// Change the size without editing the file:
//   iverilog -g2012 -Ptb_systolic_array.N=8 -Ptb_systolic_array.K_MAX=32 -o sim.vvp ...
//
// Run:
//   iverilog -g2012 -o sim.vvp rtl/mac8.sv rtl/pe8.sv rtl/systolic_array.sv tb/tb_systolic_array.sv
//   vvp sim.vvp
//   vvp sim.vvp +seed=42      (different random sequence)

module tb_systolic_array;

    parameter int N            = 4;    // array size (N x N PEs)
    parameter int K_MAX        = 16;   // longest inner dimension tested
    parameter int RANDOM_TESTS = 500;

    // ------------------------------------------------------------------
    // Signals
    // ------------------------------------------------------------------
    logic clk = 0, rst_n = 0;

    logic [N-1:0][7:0] a_in = '0, b_in = '0;
    logic [N-1:0]      a_valid_in = '0, b_valid_in = '0, clear_in = '0;

    // All N*N 32-bit results as one flat vector. This matches any packed acc
    // declaration with the same layout, e.g. [N-1:0][N-1:0][31:0].
    logic [N*N*32-1:0] acc_flat;

    // ------------------------------------------------------------------
    // DUT and clock
    // ------------------------------------------------------------------
    systolic_array #(.N(N)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .a_in       (a_in),
        .a_valid_in (a_valid_in),
        .clear_in   (clear_in),
        .b_in       (b_in),
        .b_valid_in (b_valid_in),
        .acc        (acc_flat)
    );

    always #5 clk = ~clk;   // 10 ns period

    // Result of PE(i,j) = C[i][j], as a signed number
    function automatic int result(input int i, input int j);
        return $signed(acc_flat[(i*N + j)*32 +: 32]);
    endfunction

    // ------------------------------------------------------------------
    // Test data and reference model
    // ------------------------------------------------------------------
    // Sized 2*K_MAX so back-to-back tests can hold two matrix pairs one after the other
    logic signed [7:0] A [N][2*K_MAX]; // N x K   (only the first K columns are used)
    logic signed [7:0] B [2*K_MAX][N]; // K x N   (only the first K rows are used)
    int                C [N][N];       // expected result
    int                K;              // total stream length for the current test
    int                K2_START;       // back-to-back only: where the second matrix pair starts
                                       // (0 = normal single test)

    int errors = 0;
    int tests  = 0;
    int i, j, k, c;                    // loop variables: declared once, assigned in loops
                                       // (Icarus sets "int x = ..." inside a loop only once)

    task automatic compute_expected();
        for (i = 0; i < N; i++)
            for (j = 0; j < N; j++) begin
                C[i][j] = 0;
                for (k = K2_START; k < K; k++)   // back-to-back: only the second pair counts
                    C[i][j] = C[i][j] + int'(A[i][k]) * int'(B[k][j]);
            end
    endtask

    // Fill A and B with random values (any int8: -128..127)
    task automatic randomize_AB();
        for (i = 0; i < N; i++)
            for (k = 0; k < K; k++)
                A[i][k] = $urandom;
        for (k = 0; k < K; k++)
            for (j = 0; j < N; j++)
                B[k][j] = $urandom;
    endtask

    // Fill A and B with one constant value
    task automatic fill_AB(input int a_val, input int b_val);
        for (i = 0; i < N; i++)
            for (k = 0; k < K; k++)
                A[i][k] = a_val;
        for (k = 0; k < K; k++)
            for (j = 0; j < N; j++)
                B[k][j] = b_val;
    endtask

    // ------------------------------------------------------------------
    // Feed A and B with skewing.
    //
    // On feed cycle c (0 .. K+N-2):
    //   row i of A gets A[i][c - i]   (valid only when 0 <= c - i < K)
    //   col j of B gets B[c - j][j]   (valid only when 0 <= c - j < K)
    //   clear for row i is high on that row's first element (c - i == 0),
    //   and in back-to-back tests also on the second pair's first element
    // ------------------------------------------------------------------
    task automatic feed_matrices();
        for (c = 0; c < K + N - 1; c++) begin
            @(negedge clk);
            for (i = 0; i < N; i++) begin
                k = c - i;
                if (k >= 0 && k < K) begin
                    a_in[i]       = A[i][k];
                    a_valid_in[i] = 1'b1;
                    clear_in[i]   = (k == 0) || (K2_START > 0 && k == K2_START);
                end else begin
                    a_in[i]       = '0;
                    a_valid_in[i] = 1'b0;
                    clear_in[i]   = 1'b0;
                end
            end
            for (j = 0; j < N; j++) begin
                k = c - j;
                if (k >= 0 && k < K) begin
                    b_in[j]       = B[k][j];
                    b_valid_in[j] = 1'b1;
                end else begin
                    b_in[j]       = '0;
                    b_valid_in[j] = 1'b0;
                end
            end
        end

        // Back to idle
        @(negedge clk);
        a_in = '0; b_in = '0; a_valid_in = '0; b_valid_in = '0; clear_in = '0;
    endtask

    // Compare every PE against C
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

        // The bottom-right PE gets its last product N-1 cycles after the last
        // input enters, plus one cycle to accumulate. Wait a little extra.
        repeat (N + 1) @(negedge clk);
        compare(label);

        // With all inputs idle, results must hold
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
        $display("tb_systolic_array: N = %0d, K_MAX = %0d, seed = %0d", N, K_MAX, seed);
        void'($urandom(seed));

        // Reset
        K2_START = 0;
        #12 rst_n = 1;

        // --- Directed tests -------------------------------------------

        // Identity: A x I = A   (K = N)
        K = N;
        randomize_AB();
        for (k = 0; k < K; k++)
            for (j = 0; j < N; j++)
                B[k][j] = (k == j) ? 1 : 0;
        run_test("identity");

        // K = 1: each result is a single product (outer product of a column and a row)
        K = 1;
        randomize_AB();
        run_test("K = 1");

        // Largest results: every product is (-128) x (-128) = 16384
        K = K_MAX;
        fill_AB(-128, -128);
        run_test("all -128");

        // Most negative results: every product is (-128) x 127
        K = K_MAX;
        fill_AB(-128, 127);
        run_test("-128 x 127");

        // Zeros right after data: clear must reset every PE
        K = N;
        fill_AB(0, 77);
        run_test("zeros after data");

        // --- Back-to-back streaming ------------------------------------
        // Two random matrix pairs with no idle cycle between them. A design where
        // clear does not travel with a (e.g. reaches the whole row at once) passes
        // the tests above but fails here.
        for (int t = 0; t < 50; t++) begin
            K2_START = $urandom_range(1, K_MAX);        // length of the first pair
            K        = K2_START + $urandom_range(1, K_MAX);
            randomize_AB();
            run_test($sformatf("back-to-back %0d", t));
        end
        K2_START = 0;

        // --- Random tests: random K each time -------------------------
        for (int t = 0; t < RANDOM_TESTS; t++) begin
            K = $urandom_range(1, K_MAX);
            randomize_AB();
            run_test($sformatf("random %0d", t));
        end

        // --- Summary ---------------------------------------------------
        if (errors == 0) $display("PASS: all %0d matrix multiplications correct (N = %0d)", tests, N);
        else             $display("FAIL: %0d wrong results in %0d tests (N = %0d)", errors, tests, N);
        $finish;
    end

endmodule