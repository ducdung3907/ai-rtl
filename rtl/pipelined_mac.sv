module mac8 (
    input logic clk,
    input logic rst_n,

    input logic signed [7:0] a,
    input logic signed [7:0] b,

    input logic valid_in,
    input logic clear,

    output logic signed [31:0] acc
);

    logic signed [15:0] prod;
    logic valid1,clear1;

    always_ff @(posedge clk) begin
        prod <= a*b;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid1 <= 1'b0;
            clear1 <= 1'b0;
        end else begin
            valid1 <= valid_in;
            clear1<= clear;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc <= '0;
        end else if (clear1&&valid1) begin
            acc <= prod;
        end else if (clear1) begin
            acc <= '0;
        end else if (valid1) begin
            acc <= acc + prod;
        end
    end

endmodule
