`timescale 1ns/1ps

module tb_skew;
    parameter N = 4;
    parameter  int RANDOM_CYCLES = 2000;
    localparam int HIST_DEPTH = RANDOM_CYCLES + 4*N + 16;  
    logic clk = 0;
    logic rst_n = 0;
    logic start_in = 0;
    logic valid_in = 0;
    logic [N-1:0][7:0] data_in = 0;
    logic [N-1:0][7:0] data_out;
    logic [N-1:0] valid_out, start_out;

    skew #(.N(N)) dut (.*);

    always #5 clk = ~clk;

    logic [7:0] hist_data [HIST_DEPTH][N];
    logic hist_valid [HIST_DEPTH];
    logic hist_start [HIST_DEPTH];

    int cycle = 0;
    int checks = 0, errors = 0;

    task automatic drive(input logic [N-1:0][7:0] din, input logic vin, sin);
        if (cycle >= HIST_DEPTH) begin
            $fatal(1, "history full: increase HIST_DEPTH");
        end
        data_in = din;
        start_in = sin;
        valid_in = vin;
        for (int i = 0; i < N; i++) begin
        hist_data[cycle][i] = din[i];
        end
        hist_valid[cycle] = vin;
        hist_start[cycle] = sin;
    endtask

    task automatic check(input string label);
        for (int i = 0; i< N; i++) begin
            int scr = cycle - i;
            if (scr >= 0) begin
                if ((hist_data[scr][i]) !== (data_out[i])) begin
                    $display("FAIL: %s, Data output mismatch at cycle %0d, lane %0d, got %0d, expected %0d", label, cycle, i, data_out[i], hist_data[scr][i]);
                    errors++;
                end 
                if ((hist_valid[scr]) !== (valid_out[i])) begin
                    $display("FAIL: %s, Valid output mismatch at cycle %0d, lane %0d, got %0d, expected %0d", label, cycle, i, valid_out[i], hist_valid[scr]);
                    errors++;
                end 
                if ((hist_start[scr]) !== (start_out[i])) begin
                    $display("FAIL: %s, Start output mismatch at cycle %0d, lane %0d, got %0d, expected %0d", label, cycle, i, start_out[i], hist_start[scr]);
                    errors++;
                end
            end else begin
                if ((valid_out[i] !== 0)) begin
                    $display("FAIL: %s, Reset bug at valid output, cycle %0d, lane %0d, got %0d, expected 0", label, cycle, i, valid_out[i]);
                    errors++;
                end
                if ((start_out[i] !== 0)) begin
                    $display("FAIL: %s, Reset bug at start output, cycle %0d, lane %0d, got %0d, expected 0", label, cycle, i, start_out[i]);
                    errors++;
                end
            end
            checks = checks + 2;
        end
        cycle++;
    endtask

    function automatic logic signed [7:0] rand_val();
        case ($urandom_range(0, 9))
        0:       return -128;           
        1:       return 127;
        2:       return 0;
        default: return $urandom;       
        endcase
    endfunction

    logic [N-1:0][7:0] d;

    int seed;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) begin
            seed = 1;
        end
        $display("seed = %0d", seed);
        void'($urandom(seed));

        for (int i = 0; i < N; i++) data_in[i] = 8'hAA;
        valid_in = 1;
        start_in = 1;
        repeat (3) @(negedge clk);

        for (int i = 1; i < N; i++) begin
            checks += 2;
            if (valid_out[i] !== 0 || start_out[i] !== 0) begin
                errors++;
                $display("FAIL: reset, lane %0d: valid=%b start=%b during reset, expected 0",
                         i, valid_out[i], start_out[i]);
            end
        end
        checks += 3;
        if (data_out[0] !== 8'hAA || valid_out[0] !== 1 || start_out[0] !== 1) begin
            errors++;
            $display("FAIL: reset, lane 0 should pass inputs straight through");
        end

        data_in  = '0;
        valid_in = 0;
        start_in = 0;
        @(negedge clk);
        rst_n = 1;

        $display("\nImpulse Test: Applying a single-cycle valid input and observing its propagation through each lane (valid_out per cycle, lane 0 is the rightmost bit):");
        for (int k = 0; k < N + 3; k++) begin
            @(negedge clk);
            for (int i = 0; i < N; i++) d[i] = (k == 0) ? 8'(i + 1) : 8'd0;
            drive(d, k == 0, k == 0);
            #1;
            $display("  cycle %2d: valid_out = %b", cycle, valid_out);
            check("impulse");
        end

        $display("\nCounting pattern ('--' = not valid):");
        $write("cycle |");
        for (int i = 0; i < N; i++) $write(" lane%0d", i);
        $display("");

        for (int k = 0; k < N + 6; k++) begin
            @(negedge clk);
            for (int i = 0; i < N; i++) d[i] = 8'(10 * k + i);
            drive(d, k < 6, k == 0);
            #1;
            $write("%5d |", cycle);
            for (int i = 0; i < N; i++)
                if (valid_out[i]) $write("  %4d", data_out[i]);
                else              $write("    --");
            $display("");
            check("counting");
        end

        for (int k = 0; k < 2 * N + 4; k++) begin
            @(negedge clk);
            for (int i = 0; i < N; i++) d[i] = (k % 2) ? 8'h00 : 8'hFF;
            drive(d, k % 2 == 0, 0);
            #1;
            check("toggle");
        end

        $display("\nRandomized pattern:");
        for (int k = 0; k < RANDOM_CYCLES; k++) begin
            logic [N-1:0][7:0] d_rand;
            logic rand_valid, rand_start;

            @(negedge clk);
            for (int i = 0; i < N; i++) begin
                d_rand[i] = rand_val();
            end
            rand_valid = ($urandom_range(0, 99) < 85);
            rand_start = ($urandom_range(0, 99) < 15);

            drive(d_rand, rand_valid, rand_start);
            #1;
            check("random");
        end

        if (errors == 0) begin
            $display("\nPASS: all %0d checks passed with no errors (N = %0d)", checks, N);
        end else begin
            $display("FAIL: %0d errors in %0d checks (N = %0d)", errors, checks, N);
        end

        $finish;
    end
endmodule
