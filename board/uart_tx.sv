module uart_tx #(
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD   = 115_200
)(
    input  logic clk, rst_n,
    input  logic [7:0] data,     
    input  logic valid,    
    output logic ready,    
    output logic tx       
);

typedef enum logic [1:0]{
    IDLE,
    START,
    DATA,
    STOP
} state_t;

state_t state, next_state;
logic next_tx;

localparam int CLKS_PER_BIT = (CLK_HZ + BAUD/2) / BAUD ; //verilog always round down so implement this trick

logic [7:0] data_cache;

logic [$clog2(CLKS_PER_BIT)-1:0] baud_counter;
logic [2:0] bit_index;


always_ff @(posedge clk or negedge rst_n ) begin
    if (!rst_n) begin
        state <= IDLE;
        baud_counter <= '0;
        tx <= 1;
        bit_index <= '0;
        data_cache <= '0;
    end else begin
        state <= next_state;
        tx <= next_tx;
        if (state != IDLE) begin
            if (baud_counter == (CLKS_PER_BIT -1)) begin
                baud_counter <= '0;
                if ((state == DATA)&&(bit_index != 7)) begin
                    bit_index <= bit_index + 1;
                end else begin
                    bit_index <= '0;
                end
            end else begin
                baud_counter <= baud_counter + 1;
            end
        end    
        if (valid && (state == IDLE)) begin
            data_cache <= data;
            baud_counter <= '0;
        end
    end
end

always_comb begin
    next_state = state;  
    next_tx = 1'b1;
    case (state)
        IDLE: begin
            next_tx = 1;
            if (valid) begin
                next_state = START;
            end
        end
        START: begin
            next_tx = 0;
            if (baud_counter == (CLKS_PER_BIT - 1)) begin
                next_state = DATA;
            end
        end
        DATA: begin
            next_tx = data_cache[bit_index];
            if ((baud_counter == (CLKS_PER_BIT - 1))&&(bit_index==7)) begin
                next_state = STOP;
            end
        end
        STOP: begin
            next_tx = 1;
            if (baud_counter == (CLKS_PER_BIT - 1)) begin
                next_state = IDLE;
            end
        end
        default: next_state = IDLE;
    endcase
end

assign ready = (state == IDLE);

endmodule