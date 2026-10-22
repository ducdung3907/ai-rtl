module skew #(
    parameter N = 4
)(  
    input logic clk,
    input logic rst_n,
    input logic start_in,
    input logic [N-1:0][7:0] data_in,
    input logic valid_in,
    output logic [N-1:0][7:0] data_out,
    output logic [N-1:0]valid_out,
    output logic [N-1:0]start_out //power clear_in later
);

assign data_out[0] = data_in[0];
assign valid_out[0] = valid_in;
assign start_out[0] = start_in;

genvar i;
generate
    for (i=1;i < N; i = i+1) begin : pos
        logic [i-1:0][7:0] dcache;
        logic [i-1:0] vcache,scache;
        always_ff @(posedge clk or negedge rst_n) begin
            dcache[0] <= data_in[i];
            vcache[0] <= valid_in;
            scache[0] <= start_in;
            if (!rst_n) begin
                vcache <= '0;
                scache <= '0;
            end else begin
                integer j;
                for (j=0; j<i; j=j+1) begin
                    dcache[j+1] <= dcache[j];
                    vcache[j+1] <= vcache[j];
                    scache[j+1] <= scache[j];
                end
            end
        end
        assign data_out[i] = dcache [i-1];
        assign valid_out[i] = vcache [i-1];
        assign start_out[i] = scache [i-1];
    end
endgenerate
endmodule
