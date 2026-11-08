module reply_tx #(
    parameter int N = 4,
    parameter logic [7:0] OK_BYTE=8'hA6, 
    parameter logic [7:0] ERR_BYTE=8'hE6
)(
    input logic clk,
    input logic rst_n,
    input logic done,
    input logic [6:0] done_seq,
    input logic [N-1:0][3:0] digits,
    input logic err,
    input logic [6:0] err_seq,
    output logic [7:0] tx_data,
    output logic tx_valid,
    output logic busy,
    input logic tx_ready
);

    logic [N-1:0][7:0] dbytes;
    logic [(N+2)*8-1:0] msg;
    logic [$clog2(N+3)-1:0] left;

    for (genvar i = 0; i<N; i++) begin : digits_pad
        assign dbytes[i] = {4'b0000,digits[i]}; 
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            msg <= '0;
            left <= '0;
        end else if (done&&!busy) begin
            msg <= {dbytes,1'b0,done_seq,OK_BYTE};
            left <= N+2;
        end else if (err&&!busy) begin
            msg <= {1'b0,err_seq,ERR_BYTE};
            left <= 2;
        end else if (tx_valid&&tx_ready) begin
            msg <= msg >> 8;
            left <= left - 1'b1;
        end
    end

    assign busy = (left != 0);
    assign tx_valid = busy;
    assign tx_data = msg[7:0];

endmodule