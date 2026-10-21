module tb_mac8;                     

    logic clk = 0, rst_n = 0;        
    logic signed [7:0]  a, b;
    logic valid_in, clear;
    logic signed [31:0] acc;

    mac8 dut (.*);                   

    always #5 clk = ~clk;            

    initial begin                   
        a = 0; b = 0; valid_in = 0; clear = 0;
        #12 rst_n = 1;               

        @(negedge clk);              
        a = 3; b = 4; valid_in = 1; clear = 1;   

        @(negedge clk);
        a = 2; b = 5; clear = 0;                 

        @(negedge clk);
        valid_in = 0;                            

        @(negedge clk);              
        if (acc !== 22) $display("FAIL: acc = %0d, expected 22", acc);
        else            $display("PASS: acc = 22");

        $finish;
    end
endmodule