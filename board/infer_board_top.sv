`timescale 1ns/1ps

module infer_board_top #(
    parameter int N = 4,
    parameter int MAC_LAT = 2,
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD = 1_000_000,
    parameter W_FILE = "weights.mem", 
    parameter B1_FILE = "bias1.mem", 
    parameter B2_FILE = "bias2.mem" 
)(
    input  logic sys_clk,
    input  logic sys_rst_n,
    input  logic uart_rx,
    output logic uart_tx,
    output logic [1:0] led
);
    logic rst_n_1,rst_n;

    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            rst_n <= 0;
            rst_n_1 <= 0;
        end else begin 
            rst_n_1 <= sys_rst_n;
            rst_n <= rst_n_1;
        end
    end

    logic [7:0] rx_data;
    logic rx_valid;
    uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)
    )u_rx(
        .clk(sys_clk),
        .rst_n(rst_n),
        .rx(uart_rx),
        .data(rx_data),
        .valid(rx_valid)
    );

    logic in_we, frame_err, frame_ok;
    logic [$clog2(784)-1:0] in_waddr;
    logic [31:0] in_wdata;
    logic [6:0] in_seq;

    frame_rx #(.N_STEPS(784),.START(8'hA6)
    )f_rx(
        .clk(sys_clk),
        .rst_n(rst_n),
        .rx_valid(rx_valid),
        .rx_data(rx_data),
        .ram_we(in_we),
        .ram_waddr(in_waddr),
        .ram_wdata(in_wdata),
        .frame_ok(frame_ok),
        .frame_err(frame_err),
        .frame_abort(),
        .frame_seq(in_seq)
    );

    logic done;
    logic [6:0] done_seq;
    logic [N-1:0][3:0] digits;

    infer_core #(.N(N),.MAC_LAT(MAC_LAT),
    .W_FILE(W_FILE),.B1_FILE(B1_FILE),.B2_FILE(B2_FILE)
    )i_core(
        .clk(sys_clk),
        .rst_n(rst_n),
        .in_we(in_we),
        .in_waddr(in_waddr),
        .in_wdata(in_wdata),
        .start(frame_ok),
        .start_seq(in_seq),
        .busy(),
        .done(done),
        .done_seq(done_seq),
        .digits(digits)
    );
    

    logic busy, tx_valid;
    logic [7:0] tx_data;
    logic tx_ready;

    reply_tx #(.N(N),.OK_BYTE(8'hA6),.ERR_BYTE(8'hE6)
    )r_tx(
        .clk(sys_clk),
        .rst_n(rst_n),
        .done(done),
        .done_seq(done_seq),
        .digits(digits),
        .err(frame_err),
        .err_seq(in_seq),
        .tx_data(tx_data),
        .tx_valid(tx_valid),
        .busy(busy),
        .tx_ready(tx_ready)
    );

    uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)
    )u_tx(
        .clk(sys_clk),
        .rst_n(rst_n),
        .data(tx_data),
        .valid(tx_valid),
        .ready(tx_ready),
        .tx(uart_tx)
    );

    logic [1:0] led_state;
    logic [$clog2((CLK_HZ/2)+1)-1:0] counter;
    logic busy_d;

    always_ff @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            counter   <= '0;
            led_state <= 2'b11;
            busy_d <= 1'b0;
        end else begin
            busy_d <= busy;
            if (counter == ((CLK_HZ/2) - 1)) begin
                led_state[0] <= ~led_state[0];
                counter <= '0;
            end else begin
                counter <= counter + 1;
            end
            if (busy&&!busy_d) begin
                led_state[1] <= ~led_state[1];
            end
        end
    end 

    assign led = ~led_state;

endmodule