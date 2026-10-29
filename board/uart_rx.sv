module uart_rx #(
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD   = 115_200
)(
    input  logic clk, rst_n,
    input  logic rx,          
    output logic [7:0] data,       
    output logic valid    
);
    
    localparam int CLKS_PER_BIT = (CLK_HZ + BAUD/2) / BAUD ;
    localparam int HALF_CLKS_PER_BIT = CLKS_PER_BIT / 2;

    typedef enum logic [1:0]{
        IDLE,
        START,
        DATA,
        STOP
    } state_t;

    state_t state, next_state;

    logic [$clog2(CLKS_PER_BIT)-1:0] baud_counter;
    logic [2:0] bit_index;
    logic [7:0] data_cache;
    //sync
    logic rx_s1, rx_s2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s1 <= '1;
            rx_s2 <= '1;
        end else begin
            rx_s2 <= rx_s1;
            rx_s1 <= rx;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= IDLE;
        data         <= '0;
        valid        <= 1'b0;
        baud_counter <= '0;
        bit_index    <= '0;
    end else begin
        state <= next_state;
        valid <= 1'b0;                             
        case (state)
            IDLE: begin
                baud_counter <= '0;                 
            end

            START: begin
                if (baud_counter == HALF_CLKS_PER_BIT - 1) begin
                    baud_counter <= '0;            
                    bit_index    <= '0;
                end else begin
                    baud_counter <= baud_counter + 1;
                end
            end

            DATA: begin
                if (baud_counter == CLKS_PER_BIT - 1) begin
                    baud_counter <= '0;
                    data_cache[bit_index] <= rx_s2; 
                    bit_index <= bit_index + 1;
                end else begin
                    baud_counter <= baud_counter + 1;
                end
            end

            STOP: begin
                if (baud_counter == CLKS_PER_BIT - 1) begin
                    baud_counter <= '0;
                    if (rx_s2) begin
                        data <= data_cache;
                        valid <= 1'b1;
                    end
                end else begin
                    baud_counter <= baud_counter + 1;
                end
            end
        endcase
    end
end

    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (!rx_s2) begin
                    next_state = START;
                end
            end
            START: begin
                if (baud_counter == (HALF_CLKS_PER_BIT-1)) begin
                    if (!rx_s2) begin
                        next_state = DATA;
                    end else begin
                        next_state = IDLE;
                    end
                end 
            end
            DATA: begin
                if ((baud_counter == (CLKS_PER_BIT - 1))&&(bit_index==7)) begin
                    next_state = STOP;
                end
            end
            STOP: begin
                if (baud_counter == (CLKS_PER_BIT - 1)) begin
                    next_state = IDLE;
                end 
            end
            default: next_state = IDLE;
        endcase      
    end

endmodule