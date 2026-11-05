`timescale 1ns/1ps

module res_buf #(
    parameter int N = 4
)(
    input logic clk,
    input logic rst_n,

    input logic [N-1:0][N-1:0][31:0] acc,

    input logic capture,
    output logic [7:0] out_data,
    output logic out_valid,

    input logic out_ready,
    output logic busy
);

logic [N*N*32-1:0] acc_cache;
logic [$clog2(4*N*N)-1:0] counter;

assign out_valid = busy;
assign out_data = acc_cache[7:0];

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        acc_cache <= 0;
        counter <= 0;
        busy <= 0;
    end else begin
        if (capture&&(!busy)) begin
            acc_cache <= acc;
            counter <= 0;
            busy <= 1;
        end else if (busy) begin
            if (out_valid&&out_ready) begin
                if (counter == 4*N*N-1) begin
                    busy <= 0;
                end else begin
                    counter <= counter + 1;
                    acc_cache <= acc_cache >> 8;
                end
            end
        end
    end
end

endmodule