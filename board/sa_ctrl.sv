`timescale 1ns/1ps

module sa_ctrl #(
    parameter int N = 4
)(
    input logic clk,
    input logic rst_n,
    // from sync_fifo (read side)
    input logic [7:0] rd_data,
    input logic rd_valid,
    output logic rd_ready,
    // to complete_sa
    output logic [N-1:0][7:0] a_col,
    output logic [N-1:0][7:0] b_row,
    output logic start,
    output logic valid,
    output logic last,
    input logic done,
    // to res_buf
    input logic res_busy,
    output logic capture,
    // status
    output logic job_done,
    output logic ctrl_busy
);

localparam int CW = (N > 1) ? $clog2(N) : 1;
logic [1:0] k_counter;
logic [CW-1:0] counter;
logic [1:0][7:0] k_cache;
logic a_or_b;
logic [15:0] step_counter;

typedef enum logic [2:0] {
    IDLE,
    K_IN,
    DATA,
    WAIT_DONE,
    HANDOFF
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
        step_counter <= '0;
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
                if (rd_valid && rd_ready) begin
                    k_cache[k_counter] <= rd_data;
                    k_counter <= k_counter + 1;
                end
            end
            DATA: begin
                if (rd_valid && rd_ready) begin
                    if (!a_or_b) begin
                        a_col[counter] <= rd_data;
                    end else begin
                        b_row[counter] <= rd_data;
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
        endcase
    end
end

always_comb begin
    next_state = state;
    case(state)
        IDLE: begin
            if (rd_valid && rd_ready && (rd_data == 8'hA5)) begin
                next_state = K_IN;
            end
        end
        K_IN: begin
            if (rd_valid && rd_ready && k_counter == 1) begin
                if ({rd_data, k_cache[0]} == 16'b0)
                    next_state = IDLE;
                else
                    next_state = DATA;
            end
        end
        DATA: begin
            if (rd_valid && rd_ready && a_or_b && counter == (N-1) && k_cache == 1)
                next_state = WAIT_DONE;
        end
        WAIT_DONE: begin
            if (done)
                next_state = HANDOFF;
        end
        HANDOFF: begin
            if (!res_busy)
                next_state = IDLE;
        end
        default: next_state = IDLE;
    endcase
end

assign rd_ready = (state == IDLE) || (state == K_IN) || (state == DATA);
assign capture = (state == HANDOFF) && !res_busy;
assign job_done = capture;
assign ctrl_busy = (state != IDLE);

endmodule
