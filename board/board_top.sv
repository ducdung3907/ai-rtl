`timescale 1ns/1ps

module board_top #(
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD = 1_000_000
)(
    input  logic       sys_clk,
    input  logic       sys_rst_n,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [1:0] led
);

logic [$clog2(CLK_HZ)-1:0] counter;


logic rst_n_1,rst_n;
logic [1:0] led_state;
logic [7:0] rx_data;
logic rx_valid;
logic pending;
logic tx_ready;

always_ff @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        rst_n <= 0;
        rst_n_1 <= 0;
    end else begin //metastability protector
        rst_n_1 <= sys_rst_n;
        rst_n <= rst_n_1;
    end
end

always_ff @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        pending <= 0;
    end else if (rx_valid) begin
        pending <= 1;
    end else if (pending&&tx_ready) begin
        pending <= 0;
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
    .data(rx_data),
    .valid(pending),
    .ready(tx_ready),
    .tx(uart_tx)
);

always_ff @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        counter <= '0;
        led_state <= '0;
    end else begin
        if (counter == (CLK_HZ/2) - 1) begin
            led_state[0] <= ~ led_state[0];
            counter <= '0;
        end else begin
            counter <= counter + 1;
        end
        if (rx_valid) begin
            led_state[1] <= ~ led_state[1];
        end
    end
end

assign led = ~led_state;
endmodule
