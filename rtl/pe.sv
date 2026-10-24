module pe8 #(
    parameter int MAC_LAT = 2
) (
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

generate
    if (MAC_LAT == 1) begin
        mac8 mac (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(a_valid_in&&b_valid_in),
        .clear(clear_in),
        .a(a_in),
        .b(b_in),
        .acc(acc));
    end else if (MAC_LAT == 2) begin
        mac8_pipe mac (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(a_valid_in&&b_valid_in),
        .clear(clear_in),
        .a(a_in),
        .b(b_in),
        .acc(acc));
    end else begin
        $fatal(1, "MAC_LAT must be 1 or 2, got %0d", MAC_LAT);;
    end
endgenerate

always_ff @(posedge clk) begin
    a_out <= a_in;
    b_out <= b_in;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
           clear_out   <= 1'b0;
           a_valid_out <= 1'b0;
           b_valid_out <= 1'b0;
       end else begin
           clear_out   <= clear_in;
           a_valid_out <= a_valid_in;
           b_valid_out <= b_valid_in;
       end
   end
endmodule