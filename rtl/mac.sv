module mac8 (
    input logic clk,
    input logic rst_n,

    input logic signed [7:0] a,
    input logic signed [7:0] b,

    input logic valid_in,
    input logic clear,

    output logic signed [31:0] acc
);

    logic signed [31:0] next_acc;

    always_comb begin
        next_acc = acc;
        if (clear&&valid_in) begin
            next_acc = a*b;
        end else if (clear) begin
            next_acc = '0;
        end else if (valid_in) begin
            next_acc = acc + a*b;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= '0;
        end else begin
            acc <= next_acc;
        end
    end

endmodule
