`timescale 1ns/1ps

// Self-checking testbench for sa2x2 (2x2 output-stationary systolic array).
//
// For each test it:
//   1. Picks matrices A and B (2x2, signed int8)
//   2. Computes the expected C = A x B in the testbench (reference model)
//   3. Feeds A and B into the array with skewing:
//        row i of A enters i cycles late, column j of B enters j cycles late
//   4. Waits for the array to finish, then compares all four results
//
// Works with either acc declaration in sa2x2:
//   output logic [3:0][31:0]      acc   (acc[i*2+j])
//   output logic [1:0][1:0][31:0] acc   (acc[i][j])
// Both are the same 128 bits, so the testbench reads acc as one flat vector.
//
// Run:
//   iverilog -g2012 -o sim.vvp rtl/mac8.sv rtl/pe8.sv rtl/sa2x2.sv tb/tb_sa2x2.sv && vvp sim.vvp
//   vvp sim.vvp +seed=42      (different random sequence)

module tb_sa2x2;

    localparam int N = 2;

    // ------------------------------------------------------------------
    // Signals
    // ------------------------------------------------------------------
    logic clk = 0, rst_n = 0;

    logic [N-1:0][7:0] a_in = '0, b_in = '0;
    logic [N-1:0]      a_valid_in = '0, b_valid_in = '0, clear_in = '0;

    logic [N*N*32-1:0] acc_flat;   // all four 32-bit results packed together

    // ------------------------------------------------------------------
    // DUT and clock
    // ------------------------------------------------------------------
    sa2x2 dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .a_in       (a_in),
        .b_in       (b_in),
        .a_valid_in (a_valid_in),
        .b_valid_in (b_valid_in),
        .clear_in   (clear_in),
        .acc        (acc_flat)
    );

    always #5 clk = ~clk;   // 10 ns period

    // Result of PE(i,j), as a signed number
    function automatic int result(input int i, input int j);
        return $signed(acc_flat[(i*N + j)*32 +: 32]);
    endfunction

    // ------------------------------------------------------------------
    // Test data and reference model
    // ------------------------------------------------------------------
    logic signed [7:0] A [N][N];
    logic signed [7:0] B [N][N];
    int                C [N][N];   // expected result

    int errors = 0;
    int tests  = 0;
    int i, j, k, c;                // loop variables: declared once, assigned in loops

    // Load A and B element by element (Icarus can't assign a whole array at once)
    task automatic set_AB(input int a00, input int a01, input int a10, input int a11,
                          input int b00, input int b01, input int b10, input int b11);
        A[0][0] = a00; A[0][1] = a01; A[1][0] = a10; A[1][1] = a11;
        B[0][0] = b00; B[0][1] = b01; B[1][0] = b10; B[1][1] = b11;
    endtask

    task automatic compute_expected();
        for (i = 0; i < N; i++)
            for (j = 0; j < N; j++) begin
                C[i][j] = 0;
                for (k = 0; k < N; k++)
                    C[i][j] = C[i][j] + int'(A[i][k]) * int'(B[k][j]);
            end
    endtask

    // ------------------------------------------------------------------
    // Feed A and B with skewing.
    //
    // On feed cycle c:
    //   row i of A gets A[i][c - i]   (valid only when 0 <= c - i < N)
    //   col j of B gets B[c - j][j]   (valid only when 0 <= c - j < N)
    //   clear for row i is high on that row's first element (c - i == 0)
    //
    // For N = 2 this is the timing table:
    //   cycle | row 0 | row 1 | col 0 | col 1
    //     0   |  A00  |   -   |  B00  |   -
    //     1   |  A01  |  A10  |  B10  |  B01
    //     2   |   -   |  A11  |   -   |  B11
    // ------------------------------------------------------------------
    task automatic feed_matrices();
        for (c = 0; c < 2*N - 1; c++) begin
            @(negedge clk);
            for (i = 0; i < N; i++) begin
                k = c - i;
                if (k >= 0 && k < N) begin
                    a_in[i]       = A[i][k];
                    a_valid_in[i] = 1'b1;
                    clear_in[i]   = (k == 0);
                end else begin
                    a_in[i]       = '0;
                    a_valid_in[i] = 1'b0;
                    clear_in[i]   = 1'b0;
                end
            end
            for (j = 0; j < N; j++) begin
                k = c - j;
                if (k >= 0 && k < N) begin
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

    // ------------------------------------------------------------------
    // One full test: compute expected, feed, wait, compare
    // ------------------------------------------------------------------
    task automatic run_test(input string label);
        compute_expected();
        feed_matrices();

        // Data needs up to N-1 more cycles to reach the bottom-right PE,
        // plus one cycle for the last accumulation. Wait a little extra.
        repeat (N + 1) @(negedge clk);

        tests++;
        for (i = 0; i < N; i++)
            for (j = 0; j < N; j++)
                if (result(i, j) !== C[i][j]) begin
                    errors++;
                    if (errors <= 10)
                        $display("FAIL [%s] C[%0d][%0d] = %0d, expected %0d   (A=[[%0d,%0d],[%0d,%0d]] B=[[%0d,%0d],[%0d,%0d]])",
                                 label, i, j, result(i, j), C[i][j],
                                 A[0][0], A[0][1], A[1][0], A[1][1],
                                 B[0][0], B[0][1], B[1][0], B[1][1]);
                end
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    int seed;

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_sa2x2: seed = %0d", seed);
        void'($urandom(seed));

        // Reset
        #12 rst_n = 1;

        // --- Directed tests -------------------------------------------
        // Easy to check by hand: [[1,2],[3,4]] x [[5,6],[7,8]] = [[19,22],[43,50]]
        set_AB(1, 2, 3, 4,
               5, 6, 7, 8);
        run_test("simple");

        // Identity: A x I = A
        set_AB(-7, 12, 100, -45,
               1, 0, 0, 1);
        run_test("identity");

        // Negative numbers
        set_AB(-1, -2, -3, -4,
               5, -6, -7, 8);
        run_test("negatives");

        // Extremes: largest positive results
        set_AB(-128, -128, -128, -128,
               -128, -128, -128, -128);
        run_test("all -128");

        // Extremes: mixed signs
        set_AB(127, -128, -128, 127,
               127, -128, -128, 127);
        run_test("127 / -128 mix");

        // Zeros: results must clear back to 0
        set_AB(0, 0, 0, 0,
               9, 9, 9, 9);
        run_test("zeros after data");

        // --- Random tests ---------------------------------------------
        for (int t = 0; t < 1000; t++) begin
            for (i = 0; i < N; i++)
                for (j = 0; j < N; j++) begin
                    A[i][j] = $urandom;   // any value -128..127
                    B[i][j] = $urandom;
                end
            run_test($sformatf("random %0d", t));
        end

        // --- Summary ---------------------------------------------------
        if (errors == 0) $display("PASS: all %0d matrix multiplications correct", tests);
        else             $display("FAIL: %0d wrong results in %0d tests", errors, tests);
        $finish;
    end

endmodule