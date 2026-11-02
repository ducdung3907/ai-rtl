`timescale 1ns/1ps

module sa_ctrl #(
    parameter int N = 4
)(
    input logic clk,//used
    input logic rst_n,//used
    input logic [7:0] rx_data,//used
    input logic rx_valid,//used
    output logic [7:0] tx_data,//used
    output logic tx_valid,//used
    input logic tx_ready,//used
    output logic [N-1:0][7:0] a_col,//used
    output logic [N-1:0][7:0] b_row,//used
    output logic start,//used
    output logic valid,//used
    output logic last,//used
    input logic done,//used
    input logic [N-1:0][N-1:0][31:0] acc,//used
    output logic busy//used
);

logic [1:0]k_counter; 
logic [$clog2(N)-1:0] counter;
logic [1:0][7:0] k_cache;
logic a_or_b;
logic [N-1:0][N-1:0][31:0] acc_reg;
logic [$clog2(N)-1:0] tx_col, tx_row;
logic [1:0] byte_counter; 
logic [15:0] step_counter;

typedef enum logic [2:0] {
    IDLE,
    K_IN,
    DATA,
    WAIT_DONE,
    SEND
}state_t;

state_t state, next_state;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        counter <= '0;
        k_cache <= '0;
        state <= IDLE;
        a_or_b <= '0;
        a_col <= '0;
        b_row <= '0;
        valid <= '0;
        start <= '0;
        k_counter <= '0;
        acc_reg <= '0;
        step_counter <= '0;
        tx_col <= '0;
        tx_row <= '0;
        byte_counter <= '0;
        last <= '0;
    end else begin
        valid <= '0;
        start <= '0;
        last <= '0;
        state <= next_state;
        case(state)
            IDLE: begin
                k_counter <= '0;
                k_cache <= '0;
                step_counter <= '0;
            end
            K_IN: begin
                if (rx_valid) begin
                    k_cache[k_counter] <= rx_data; 
                    k_counter <= k_counter + 1;
                end
            end
            DATA: begin
                if (rx_valid) begin
                    if (!a_or_b) begin
                        a_col[counter] <= rx_data;
                    end else begin 
                        b_row[counter] <= rx_data;
                    end
                    if (counter == (N-1)) begin
                        if (a_or_b) begin
                            k_cache <= k_cache - 1;
                            valid <= 1;
                            start <= (step_counter == 0);
                            last <= (k_cache == 1);
                            step_counter <= step_counter + 1;
                        end
                        counter <= 0;
                        a_or_b <= ~a_or_b;
                    end else begin
                        counter <= counter + 1;
                    end
                end
            end
            WAIT_DONE: begin
                if (done) begin
                    acc_reg <= acc;
                    tx_row <= '0;
                    tx_col <= '0;
                    byte_counter <= '0;
                end
            end
            SEND: begin
                if (tx_valid && tx_ready) begin
                    if (byte_counter == 2'd3) begin
                        byte_counter <= '0;
                        if (tx_col == N-1) begin
                            tx_col <= '0;
                            if (tx_row != N-1) tx_row <= tx_row + 1'b1;
                        end else begin
                            tx_col <= tx_col + 1'b1;
                        end
                    end else begin
                        byte_counter <= byte_counter + 1'b1;
                    end
                end
            end
        endcase
    end
end

always_comb begin
    next_state = state;
    case(state)
        IDLE: begin
            if (rx_valid&&(rx_data == 8'hA5)) begin
                next_state = K_IN;
            end
        end
        K_IN: begin
            if (k_counter == 2) begin
                if (k_cache == 0) begin
                    next_state = IDLE;
                end else begin
                    next_state = DATA;
                end
            end
        end
        DATA: begin
            if (k_cache == 0) begin
                    next_state = WAIT_DONE;
                end
            end
        WAIT_DONE: begin
            if (done) next_state = SEND;
        end
        SEND: begin
            if (tx_valid && tx_ready && tx_row == N-1 &&
                tx_col == N-1 && byte_counter == 2'd3) begin
                next_state = IDLE;
            end
        end
    endcase
end

//this implementation can run on icarus
logic [N*N*32-1:0] acc_flat;
assign acc_flat = acc_reg;          // same bits: acc_reg[i][j] sits at bit (i*N + j)*32
assign tx_valid = (state == SEND);
assign tx_data  = acc_flat[(tx_row*N + tx_col)*32 + byte_counter*8 +: 8];

//this implementation cannot run on icarus but still good in vivado
/*always_comb begin
    tx_valid = (state == SEND);
    case (byte_counter)
        2'd0: tx_data = acc_reg[tx_row][tx_col][7:0];
        2'd1: tx_data = acc_reg[tx_row][tx_col][15:8];
        2'd2: tx_data = acc_reg[tx_row][tx_col][23:16];
        2'd3: tx_data = acc_reg[tx_row][tx_col][31:24];
    endcase
end*/

assign busy = (state != IDLE);
endmodule
