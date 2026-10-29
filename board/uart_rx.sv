module uart_rx #(
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD   = 115_200
)(
    input  logic clk, rst_n,
    input  logic rx,          
    output logic [7:0] data,       
    output logic valid    
);

endmodule