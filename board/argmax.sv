module argmax #(
    parameter int WIDTH = 10
)(
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic signed [31:0] in_data,
    input  logic in_last,
    output logic out_valid,
    output logic signed [31:0] out_max,
    output logic [$clog2(WIDTH)-1:0] out_index
);

logic signed [31:0] best;
logic [$clog2(WIDTH)-1:0] best_idx, idx;
logic first;                                

logic take;                                  
assign take = first || (in_data > best);      

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        first <= 1'b1; idx <= '0; best <= '0; best_idx <= '0;
        out_valid <= 1'b0; out_max <= '0; out_index <= '0;
    end else begin
        out_valid <= 1'b0;                 
        if (in_valid) begin
            if (take) begin
                best     <= in_data;
                best_idx <= idx;
            end
            if (in_last) begin
                out_valid <= 1'b1;
                out_max   <= take ? in_data : best;
                out_index <= take ? idx     : best_idx;
                first     <= 1'b1;           
                idx       <= '0;
            end else begin
                first <= 1'b0;
                idx   <= idx + 1'b1;
            end
        end
    end
end

endmodule