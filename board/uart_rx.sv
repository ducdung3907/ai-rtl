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

    typedef enum logic [1:0]{
        IDLE,
        START,
        DATA,
        STOP
    } state_t;

    logic next_state;
    //sync
    logic rx_s1, rx_s2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s1 <= '0;
            rx_s2 <= '0;
        end else begin
            rx_s2 <= rx_s1;
            rx_s1 <= rx;
        end
    end

    always_ff @(posedge clk or negedge)

    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin

        endcase

    end

endmodule