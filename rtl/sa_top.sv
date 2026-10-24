module complete_sa #(
    parameter N = 4
)(
    input logic clk,
    input logic rst_n,
    input logic [N-1:0][7:0] a_col, b_row,
    input logic valid,
    input logic start,
    input logic last,
    output logic done,
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
    .start_in(1'b0),
    .data_out(b_delay),
    .valid_out(b_valid),
    .start_out()
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

logic [2*N-1:0] done_cache;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done_cache <= '0;
    end else begin
        done_cache[0] <= (last&valid);
        for (int i=0;i<2*N-1;i++) begin
            done_cache[i+1]<= done_cache[i];
        end
    end
end

assign done = done_cache[2*N-1];

endmodule