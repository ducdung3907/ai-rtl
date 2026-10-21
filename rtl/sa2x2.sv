module sa2x2 (
    input logic clk,
    input logic rst_n,

    input logic [1:0][7:0] a_in, b_in,

    input logic [1:0] a_valid_in, b_valid_in,
    input logic [1:0] clear_in,

    output logic [3:0][31:0] acc
);
    
    logic [1:0] w_clr;
    logic [1:0][7:0] w_a,w_b;
    logic [1:0] w_av,w_bv;

    pe8 pe00 (
        .clk(clk),
        .rst_n(rst_n),
        .a_valid_in(a_valid_in[0]),
        .b_valid_in(b_valid_in[0]),
        .a_in(a_in[0]),
        .b_in(b_in[0]),
        .clear_in(clear_in[0]),
        .a_out(w_a[0]),
        .b_out(w_b[0]),
        .clear_out(w_clr[0]),
        .a_valid_out(w_av[0]),
        .b_valid_out(w_bv[0]),
        .acc(acc[0])
    );

    pe8 pe01 (
        .clk(clk),
        .rst_n(rst_n),
        .a_valid_in(w_av[0]),
        .b_valid_in(b_valid_in[1]),
        .a_in(w_a[0]),
        .b_in(b_in[1]),
        .clear_in(w_clr[0]),
        .a_out(),
        .b_out(w_b[1]),
        .clear_out(),
        .a_valid_out(),
        .b_valid_out(w_bv[1]),
        .acc(acc[1])
    );

    pe8 pe10 (
        .clk(clk),
        .rst_n(rst_n),
        .a_valid_in(a_valid_in[1]),
        .b_valid_in(w_bv[0]),
        .a_in(a_in[1]),
        .b_in(w_b[0]),
        .clear_in(clear_in[1]),
        .a_out(w_a[1]),
        .b_out(),
        .clear_out(w_clr[1]),
        .a_valid_out(w_av[1]),
        .b_valid_out(),
        .acc(acc[2])
    );

    pe8 pe11 (
        .clk(clk),
        .rst_n(rst_n),
        .a_valid_in(w_av[1]),
        .b_valid_in(w_bv[1]),
        .a_in(w_a[1]),
        .b_in(w_b[1]),
        .clear_in(w_clr[1]),
        .a_out(),
        .b_out(),
        .clear_out(),
        .a_valid_out(),
        .b_valid_out(),
        .acc(acc[3])
    );
endmodule