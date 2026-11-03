`timescale 1ns/1ps

module sync_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
)(
    input logic clk,
    input logic rst_n,
    input logic wr_valid,
    input logic [WIDTH-1:0] wr_data,

    output logic full,

    output logic rd_valid,
    output logic [WIDTH-1:0] rd_data,

    input logic rd_ready,
    output logic [$clog2(DEPTH+1)-1:0] count,
    output logic overflow
);

logic [WIDTH-1:0] mem [0:DEPTH-1];

localparam int PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
logic [PTR_W-1:0] rd_ptr;
logic [PTR_W-1:0] wr_ptr;

assign rd_valid = (count != 0);
assign rd_data = mem[rd_ptr];

wire rd_fire = rd_valid && rd_ready;
wire wr_fire = wr_valid && (!full || rd_fire);

always_ff @(posedge clk) begin
    if (wr_fire) mem[wr_ptr] <= wr_data;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        count <= '0;
        rd_ptr <= '0;
        wr_ptr <= '0;
        overflow <= 1'b0;
    end else begin
        if (wr_valid && !wr_fire) overflow <= 1'b1;

        if (wr_fire) begin
            if (wr_ptr == (DEPTH -1)) begin
                wr_ptr <= '0;
            end else begin
                wr_ptr <= wr_ptr + 1'b1;
            end
        end
        if (rd_fire) begin
            if (rd_ptr == (DEPTH-1)) begin
                rd_ptr <= '0;
            end else begin
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
        case ({wr_fire, rd_fire})
            2'b10: count <= count + 1'b1; 
            2'b01: count <= count - 1'b1; 
            default: count <= count;
        endcase
    end
end

always_comb begin
    full = (count == DEPTH);
end

endmodule