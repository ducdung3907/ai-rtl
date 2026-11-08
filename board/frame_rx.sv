module frame_rx #(
    parameter int N_STEPS = 784,
    parameter START=8'hA6
)(
    input logic clk,
    input logic rst_n,
    input logic rx_valid,
    input logic [7:0] rx_data,
    output logic ram_we,
    output logic [$clog2(N_STEPS)-1:0]ram_waddr,
    output logic [31:0]ram_wdata,
    output logic frame_ok,
    output logic frame_err,
    output logic frame_abort,
    output logic [6:0] frame_seq
);
    logic [1:0] byte_index;
    logic [23:0] cache;
    logic [6:0] seq, sum;
    logic [$clog2(N_STEPS)-1:0] step;

    typedef enum logic [1:0] {
        IDLE,
        SEQ,
        PAYLOAD,
        CHECK
    } state_t;

    state_t state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cache <= '0;
            ram_waddr <= '0;
            byte_index <= '0;
            ram_we <= '0;
            sum <= '0;
            frame_abort <= '0;
            state <= IDLE;
            frame_ok <= '0;
            frame_err <= '0;
            ram_wdata <= '0;
            seq <= '0;
            sum <= '0;
            frame_seq <= '0;
            step <= '0;
        end else begin
            frame_ok <= 0; frame_err <= 0; frame_abort <= 0;
            ram_we <= 0;
            if (rx_valid && rx_data[7] && state != IDLE) begin
                frame_abort <= 1;
                if (rx_data == START) state <= SEQ;
                else                  state <= IDLE;
                sum <= '0; step <= '0; byte_index <= '0;
            end else case (state)
                IDLE: begin
                    cache <= '0;
                    ram_waddr <= '0;
                    byte_index <= '0;
                    sum <= '0;
                    step <= '0;
                    if (rx_valid&&(rx_data == START)) state <= SEQ;
                end
                SEQ: begin 
                    if (rx_valid) begin
                        seq <= rx_data[6:0];
                        state <= PAYLOAD;
                    end
                end
                PAYLOAD: begin
                    if (rx_valid) begin
                            sum <= sum + rx_data[6:0];
                        if (byte_index<3) begin
                            cache[byte_index*8+:8] <= rx_data;
                            byte_index <= byte_index + 1;
                        end else begin
                            ram_wdata <= {rx_data,cache};
                            ram_we <= 1;
                            step <= step + 1;
                            ram_waddr <= step;
                            byte_index <= '0;
                            if (step == N_STEPS - 1) begin
                                state <= CHECK;
                            end
                        end
                    end
                end 
                CHECK: begin
                    if (rx_valid) begin
                        state <= IDLE;
                        frame_seq <= seq;
                        if (rx_data[6:0]==sum) begin
                            frame_ok <= 1;
                        end else begin
                            frame_err <= 1;
                        end
                    end
                end
            endcase
        end
    end
endmodule