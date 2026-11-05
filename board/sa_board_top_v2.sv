`timescale 1ns/1ps
 
module sa_board_top #(
    parameter int N          = 4,
    parameter int MAC_LAT    = 2,
    parameter int CLK_HZ     = 50_000_000,
    parameter int BAUD       = 1_000_000,
    parameter int FIFO_DEPTH = 1024
)(
    input  logic sys_clk,
    input  logic sys_rst_n,
    input  logic uart_rx,
    output logic uart_tx,
    output logic [1:0] led
);
 
logic rst_n_1, rst_n;
 
logic [7:0] wr_data;
logic       wr_valid;
 
logic [7:0] rd_data;
logic       rd_valid, rd_ready;
logic       full, overflow;
logic [$clog2(FIFO_DEPTH+1)-1:0] count;

logic [N-1:0][7:0] a_col;
logic [N-1:0][7:0] b_row;
logic valid, start, last;
logic done;
logic [N-1:0][N-1:0][31:0] acc;
 
logic capture, res_busy, job_done, ctrl_busy;
 
logic [7:0] out_data;
logic       out_valid, out_ready;
 
logic [$clog2(CLK_HZ)-1:0] counter;
logic [1:0] led_state;
 
always_ff @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        rst_n_1 <= 1'b0;
        rst_n   <= 1'b0;
    end else begin
        rst_n_1 <= 1'b1;
        rst_n   <= rst_n_1;
    end
end
 
uart_rx #(
    .CLK_HZ(CLK_HZ),
    .BAUD(BAUD)
) u_rx (
    .clk(sys_clk),
    .rst_n(rst_n),
    .rx(uart_rx),
    .data(wr_data),
    .valid(wr_valid)
);
 
sync_fifo #(
    .WIDTH(8),
    .DEPTH(FIFO_DEPTH)
) u_fifo (.clk(sys_clk), .*);
 
sa_ctrl #(
    .N(N)
) s_ctrl (.clk(sys_clk), .*);
 
complete_sa #(
    .N(N),
    .MAC_LAT(MAC_LAT)
) c_sa (.clk(sys_clk), .*);
 
res_buf #(
    .N(N)
) u_res (.clk(sys_clk), .*, .busy(res_busy));
 
uart_tx #(
    .CLK_HZ(CLK_HZ),
    .BAUD(BAUD)
) u_tx (
    .clk(sys_clk),
    .rst_n(rst_n),
    .data(out_data),
    .valid(out_valid),
    .ready(out_ready),
    .tx(uart_tx)
);
 
always_ff @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        counter   <= '0;
        led_state <= 2'b11;
    end else begin
        if (overflow) begin
            led_state[0] <= 1'b1;           
        end else if (counter == ((CLK_HZ/2) - 1)) begin
            led_state[0] <= ~led_state[0];
        end
        if (counter == ((CLK_HZ/2) - 1)) begin
            counter <= '0;
        end else begin
            counter <= counter + 1;
        end
        if (job_done) begin
            led_state[1] <= ~led_state[1];
        end
    end
end
 
assign led = ~led_state;

endmodule