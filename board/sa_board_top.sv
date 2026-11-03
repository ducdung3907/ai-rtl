`timescale 1ns/1ps

module sa_board_top #(
    parameter int N = 4,
    parameter int MAC_LAT = 2,
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD = 1_000_000 
)(
    input logic sys_clk,
    input logic sys_rst_n,
    input logic uart_rx,
    output logic uart_tx,
    output logic [1:0] led
);

logic rst_n_1, rst_n;

logic [7:0] rx_data;
logic rx_valid;

logic [7:0] tx_data;
logic tx_valid;
logic tx_ready;

logic [N-1:0][7:0] a_col;
logic [N-1:0][7:0] b_row;

logic valid, start, last;
logic done;

logic [N-1:0][N-1:0][31:0] acc;

logic busy;
logic busy_d;
logic [$clog2(CLK_HZ)-1:0] counter;
logic [1:0] led_state;

always_ff @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        rst_n_1 <= 1'b0;
        rst_n <= 1'b0; 
    end else begin
        rst_n_1 <= 1'b1;
        rst_n <= rst_n_1;
    end
end

uart_rx #(
    .CLK_HZ(CLK_HZ),
    .BAUD(BAUD)
)u_rx(
    .clk(sys_clk),
    .rst_n(rst_n),
    .rx(uart_rx),
    .data(rx_data),
    .valid(rx_valid)
);

uart_tx #(
    .CLK_HZ(CLK_HZ),
    .BAUD(BAUD)
)u_tx(
    .clk(sys_clk),
    .rst_n(rst_n),
    .data(tx_data),
    .valid(tx_valid),
    .ready(tx_ready),
    .tx(uart_tx)
);

sa_ctrl #(
    .N(N)
)s_ctrl(.clk(sys_clk), .*);

complete_sa #(
    .N(N),
    .MAC_LAT(MAC_LAT)
)c_sa(.clk(sys_clk), .*);

always_ff @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        counter <= '0;
        led_state <= 2'b11;
        busy_d <= '0;
    end else begin
        if (counter == ((CLK_HZ/2) -1)) begin
            led_state[0] <= ~led_state[0];
            counter <= '0;
        end else begin
            counter <= counter + 1;
        end
        busy_d <= busy;
        if (busy_d&&(!busy)) begin
            led_state[1] <= ~led_state[1];
        end
    end
end

assign led = ~led_state; //active low
endmodule