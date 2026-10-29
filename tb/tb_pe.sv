`timescale 1ns/1ps

module tb_pe8;

    parameter int MAC_LAT = 2;
    parameter int RANDOM_CYCLES = 20000;

    logic clk = 0, rst_n = 0;
    logic signed [7:0] a_in = 0, b_in = 0;
    logic a_valid_in = 0, b_valid_in = 0, clear_in = 0;

    logic signed [7:0] a_out, b_out;
    logic a_valid_out, b_valid_out, clear_out;
    logic signed [31:0] acc;

    pe8 #(.MAC_LAT(MAC_LAT)) dut (.*);

    always #5 clk = ~clk;

 
    int expected = 0;
    int expected_prev [0:MAC_LAT-1];

    int errors = 0, checks = 0;
    int n_clear_valid = 0, n_extreme = 0;

    logic signed [7:0] prev_a = 0, prev_b = 0;
    logic prev_a_valid = 0, prev_b_valid = 0, prev_clear = 0;


    task automatic drive(
        input logic signed [7:0] a_i,
        input logic signed [7:0] b_i,
        input logic va,
        input logic vb,
        input logic clr
    );
        a_in       = a_i;
        b_in       = b_i;
        a_valid_in = va;
        b_valid_in = vb;
        clear_in   = clr;

        prev_a       = a_i;
        prev_b       = b_i;
        prev_a_valid = va;
        prev_b_valid = vb;
        prev_clear   = clr;

        if (clr && va && vb)
            n_clear_valid++;

        if (a_i == -128 && b_i == -128)
            n_extreme++;
        if (clr && va && vb) begin
            expected = int'(a_i) * int'(b_i);
        end else if (clr) begin
            expected = 0;
        end else if (va && vb) begin
            expected = expected + int'(a_i) * int'(b_i);
        end

        for (int k = MAC_LAT - 1; k > 0; k--)
            expected_prev[k] = expected_prev[k-1];

        expected_prev[0] = expected;

    endtask


    task automatic check(input string label);
        checks++;
        if (a_out !== prev_a ||
            b_out !== prev_b ||
            a_valid_out !== prev_a_valid ||
            b_valid_out !== prev_b_valid ||
            clear_out !== prev_clear) begin

            $display(
                "FAIL [%s] forwarding: a_out=%0d (expect %0d), b_out=%0d (expect %0d), va=%b (expect %b), vb=%b (expect %b), clr=%b (expect %b)",
                label,
                a_out, prev_a,
                b_out, prev_b,
                a_valid_out, prev_a_valid,
                b_valid_out, prev_b_valid,
                clear_out, prev_clear
            );

            errors++;
        end

        if (acc !== expected_prev[MAC_LAT-1]) begin
            $display(
                "FAIL [%s] acc = %0d, expect %0d",
                label, acc, expected_prev[MAC_LAT-1]
            );
            errors++;
        end

    endtask


    function automatic logic signed [7:0] rand_val();
        case ($urandom_range(0, 9))
            0:       return -128;
            1:       return 127;
            2:       return 0;
            default: return $urandom;
        endcase
    endfunction


    int seed;

    initial begin
        if (!$value$plusargs("seed=%d", seed)) begin
            seed = 1;
        end
        $display("tb_pe8: seed = %0d", seed);
        void'($urandom(seed));

        rst_n = 0;
        a_in = 5;
        b_in = -3;
        a_valid_in = 1;
        b_valid_in = 1;
        clear_in = 1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        checks++;
        if (a_valid_out !== 0 ||
            b_valid_out !== 0 ||
            clear_out !== 0 ||
            acc !== 0) begin
            $display(
                "FAIL [reset] va=%b, vb=%b, clr=%b, acc=%0d; expected all zeros",
                a_valid_out, b_valid_out, clear_out, acc
            );
            errors++;
        end

        a_in = 0;
        b_in = 0;
        a_valid_in = 0;
        b_valid_in = 0;
        clear_in = 0;

        rst_n = 1;

        expected = 0;
        for (int k = 0; k < MAC_LAT; k++)
            expected_prev[k] = 0;

        prev_a = 0;
        prev_b = 0;
        prev_a_valid = 0;
        prev_b_valid = 0;
        prev_clear = 0;

        @(negedge clk);
        check("idle after reset");

        drive(3, 4, 1, 1, 1);       // Clear and valid
        @(negedge clk);
        check("3*4 with clear");

        drive(2, 5, 1, 1, 0);
        @(negedge clk);
        check("+2*5");

        drive(7, 7, 1, 0, 0);       // Only a valid
        @(negedge clk);
        check("only a valid");

        drive(7, 7, 0, 1, 0);       // Only b valid
        @(negedge clk);
        check("only b valid");

        drive(-3, 2, 1, 1, 1);      // Negative product with clear
        @(negedge clk);
        check("-3*2 with clear");

        drive(-128, -128, 1, 1, 1);
        @(negedge clk);
        check("-128*-128 with clear");

        drive(-128, 127, 1, 1, 0);
        @(negedge clk);
        check("+(-128*127)");

        drive(127, 127, 1, 1, 0);
        @(negedge clk);
        check("+127*127");

        drive(9, 9, 0, 0, 1);       // Clear without valid inputs
        @(negedge clk);
        check("clear only");

        drive(1, 1, 1, 1, 1);
        @(negedge clk);
        check("1*1 with clear");

        drive(0, 0, 0, 0, 0);
        @(negedge clk);
        check("idle after directed tests");


        for (int i = 0; i < RANDOM_CYCLES; i++) begin
            drive(
                rand_val(),
                rand_val(),
                ($urandom_range(0, 3) != 0),
                ($urandom_range(0, 3) != 0),
                ($urandom_range(0, 19) == 0)
            );
            @(negedge clk);
            check("random cycle");

        end

        for (int i = 0; i < MAC_LAT; i++) begin
            drive(0, 0, 0, 0, 0);
            @(negedge clk);
            check("Wait for settling down");
        end



        if (errors == 0) begin
            $display("PASS: all %0d checks passed (MAC_LAT = %0d)", checks, MAC_LAT);
        end else begin
            $display("FAIL: %0d errors in %0d checks (MAC_LAT = %0d)", errors, checks, MAC_LAT);
        end
        $display("clear + valid: %0d", n_clear_valid);
        $display("-128 * -128:   %0d", n_extreme);
        $finish;

    end

endmodule