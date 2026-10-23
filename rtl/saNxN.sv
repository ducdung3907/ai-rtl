module systolic_array #(
    parameter N = 4
)(
    input logic clk,
    input logic rst_n,
    input logic [N-1:0][7:0] a_in,
    input logic [N-1:0] a_valid_in,
    input logic [N-1:0] clear_in,
    input logic [N-1:0][7:0] b_in,
    input logic [N-1:0] b_valid_in,
    output logic [N-1:0][N-1:0][31:0] acc
);

logic [N-1:0][N:0][7:0] w_a;
logic [N:0][N-1:0][7:0] w_b;
logic [N-1:0][N:0] w_av;
logic [N:0][N-1:0] w_bv;
logic [N-1:0][N:0] w_clr;

assign w_b[0] = b_in;
assign w_bv[0] = b_valid_in;

genvar i,j;
generate
    for (i = 0; i< N;i = i+1) begin : row
        assign w_a[i][0]   = a_in[i];
        assign w_av[i][0]  = a_valid_in[i];
        assign w_clr[i][0] = clear_in[i];
        for (j = 0; j<N; j= j+1) begin :col
            pe8 pe (
            .clk(clk),
            .rst_n(rst_n),
            .a_valid_in(w_av[i][j]),
            .b_valid_in(w_bv[i][j]),
            .a_in(w_a[i][j]),
            .b_in(w_b[i][j]),
            .clear_in(w_clr[i][j]),
            .a_out(w_a[i][j+1]),
            .b_out(w_b[i+1][j]),
            .clear_out(w_clr[i][j+1]),
            .a_valid_out(w_av[i][j+1]),
            .b_valid_out(w_bv[i+1][j]),
            .acc(acc[i][j])
            );
        end
    end 
endgenerate

endmodule
