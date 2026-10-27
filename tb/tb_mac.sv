`timescale 1ns/1ps

module tb_mac;
    logic clk = 0, rst_n = 0, valid_in = 0, clear = 0;
    logic signed [7:0] a = 0, b = 0;

    logic signed [31:0] acc1, acc2;

    mac8 dut1 (.*,.acc(acc1));
    mac8_pipe dut2 (.*,.acc(acc2));

    always #5 clk = ~clk;

    int expected = 0;
    int expected_prev = 0;
    int errors = 0, checks = 0;
    int n_clear_valid = 0, n_extreme = 0;
    task automatic drive(input logic signed [7:0] a_i, b_i, input logic v, c);
        a = a_i;
        b = b_i;
        valid_in = v;
        clear = c;
        expected_prev = expected;
        if (c && v) begin
            n_clear_valid++;   
        end
        if (a_i == -128 && b_i == -128) begin
            n_extreme++;
        end
        if (clear&&valid_in) begin
            expected = int'(a)*int'(b);
        end else if (clear) begin
            expected = '0;
        end else if (valid_in) begin
            expected = expected + int'(a)*int'(b);
        end
    endtask

    task automatic check(input string label);
        checks++;
        if (acc1 !== expected) begin
            $display ("FAIL [%s] mac8: acc = %0d, expect %0d", label, acc1, expected);
            errors++;
        end
        if (acc2 !== expected_prev) begin
            $display ("FAIL [%s] mac8_pipe: acc = %0d, expect %0d", label, acc2, expected_prev);
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
        //seed initialize
        if (!$value$plusargs("seed=%d", seed)) begin
            seed = 1;
        end
        $display("seed = %0d", seed);
        void'($urandom(seed));

        //reset test
        rst_n = 0;
        a = 5; b = -3; valid_in = 1; clear = 1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        checks++;
        if (acc1 !== 0 || acc2 !== 0) begin
            $display("FAIL [reset] acc1 = %0d, acc2 = %0d, expected 0 and 0", acc1, acc2);
            errors++;
        end

        //directed test
        a = 0; b = 0; valid_in = 0; clear = 0;
        rst_n = 1;
        expected = 0; expected_prev = 0;
        @(negedge clk); 
        check("idle after reset");  

        drive(3, 4, 1, 1);   // clear + valid
        @(negedge clk); 
        check("3*4 with clear");

        drive(2, 5, 1, 0);   
        @(negedge clk);
        check("+2*5");

        drive( 7, 7, 0, 0);   // not valid
        @(negedge clk); 
        check("hold (valid = 0)");

        drive(-3, 4, 1, 0);   
        @(negedge clk); 
        check("+(-3*4)");

        drive(-5, -6, 1, 0);   
        @(negedge clk); 
        check("+(-5*-6)");
        
        drive(0, 100, 1, 0);   
        @(negedge clk); 
        check("+0*100");

        drive(9, 9, 0, 1);   // clear without valid
        @(negedge clk); 
        check("clear only");

        drive(-128, -128, 1, 1);  // largest product
        @(negedge clk); 
        check("-128*-128 with clear");

        drive(-128, 127, 1, 0);  // most negative product
        @(negedge clk); 
        check("+(-128*127)");

        drive(127, 127, 1, 0); 
        @(negedge clk); 
        check("+127*127");

        drive(1, 1, 1, 1);   
        @(negedge clk); 
        check("1*1 with clear");

        drive(0, 0, 0, 0);  
        @(negedge clk); 
        check("idle 1");

        drive(0, 0, 0, 0);   
        @(negedge clk); 
        check("idle 2");

        //random test
        for (int n = 0; n < 20000; n++) begin
            @(negedge clk);
            check($sformatf("random cycle %0d", n));
            drive(rand_val(), rand_val(),                           
            ($urandom_range(0, 3) != 0),       
            ($urandom_range(0, 19) == 0));      
        end
        @(negedge clk); 
        check("last random cycle");

        drive(0, 0, 0, 0);
        @(negedge clk); 
        check("final idle 1");   

        drive(0, 0, 0, 0);
        @(negedge clk); 
        check("final idle 2");


        //summary
        if (errors == 0) begin
            $display("PASS: all %0d checks passed", checks);
        end else begin            
            $display("FAIL: %0d errors in %0d checks", errors, checks);
        end
        $display("clear+valid: %0d, -128*-128: %0d", n_clear_valid, n_extreme);
        $finish;
    end
endmodule

