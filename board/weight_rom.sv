module weight_rom #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 12736,
    parameter INIT_FILE = "weights.mem"
)(
    input  logic clk,
    input  logic [$clog2(DEPTH)-1:0] addr,
    output logic [WIDTH-1:0] dout
);
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    initial $readmemh(INIT_FILE, mem);

    always_ff @(posedge clk) dout <= mem[addr];
endmodule