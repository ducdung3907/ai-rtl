module simple_dp_ram #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 1024
)(
    input logic clk,
    
    input logic we,
    input logic [$clog2(DEPTH)-1:0] waddr,
    input logic [WIDTH-1:0] wdata,

    input logic [$clog2(DEPTH)-1:0] raddr,
    output logic [WIDTH-1:0] rdata
);

    logic [WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) rdata <= mem[raddr];

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end

endmodule