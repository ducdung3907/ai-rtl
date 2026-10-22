module complete_sa #(
    parameter N = 4
)(
    input logic clk,
    input logic rst_n,
    input logic [N-1:0][7:0] a_col, b_row,
    input logic valid,
    input logic start,
    output logic [N-1:0][N-1:0][31:0] acc
);

logic [N-1:0][7:0] a_delay, b_delay;
logic [N-1:0] a_valid, b_valid, a_start, b_start;

skew #(.N(N)) col (
    .clk(clk),
    .rst_n(rst_n),
    .data_in(a_col),
    .valid_in(valid),
    .start_in(start),
    .data_out(a_delay),
    .valid_out(a_valid),
    .start_out(a_start)
);

skew #(.N(N)) row (
    .clk(clk),
    .rst_n(rst_n),
    .data_in(b_row),
    .valid_in(valid),
    .start_in(start),
    .data_out(b_delay),
    .valid_out(b_valid),
    .start_out(b_start)
);

systolic_array #(.N(N)) base_sa (
    .clk(clk),
    .rst_n(rst_n),
    .a_in(a_delay),
    .b_in(b_delay),
    .clear_in(a_start),
    .a_valid_in(a_valid),
    .b_valid_in(b_valid),
    .acc(acc)
);

endmodule