// skew will delay the arithmetic of later pe => make the arithmetic true pair
module skew #(
    parameter N = 4
)(  
    input logic clk,
    input logic rst_n,
    input logic start_in,
    input logic [N-1:0][7:0] data_in,
    input logic [N-1:0]valid_in,
    output logic [N-1:0][7:0] data_out,
    output logic [N-1:0]valid_out,
    output logic [N-1:0]start_out //power clear_in later
);

logic [N-1:0] cache;

always_ff @(posedge clk or negedge rst_n) begin
    
end

endmodule