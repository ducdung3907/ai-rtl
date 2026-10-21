module pe8 (
    input logic clk,
    input logic rst_n,

    input logic a_valid_in, b_valid_in,
    input logic signed [7:0] a_in, b_in,

    input logic clear_in,

    output logic a_valid_out, b_valid_out,
    output logic signed [7:0] a_out, b_out,

    output logic clear_out,
    
    output logic signed [31:0] acc
);

mac8 mac (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(a_valid_in&&b_valid_in),
    .clear(clear_in),
    .a(a_in),
    .b(b_in),
    .acc(acc)
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
           a_out       <= '0;
           b_out       <= '0;
           clear_out   <= 1'b0;
           a_valid_out <= 1'b0;
           b_valid_out <= 1'b0;
       end else begin
           a_out       <= a_in;
           b_out       <= b_in;
           clear_out   <= clear_in;
           a_valid_out <= a_valid_in;
           b_valid_out <= b_valid_in;
       end
   end
endmodule