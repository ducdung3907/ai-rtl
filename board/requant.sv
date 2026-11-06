module requant (
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,
    input  logic signed [31:0] acc,
    input  logic signed [31:0] bias,
    input  logic [15:0] M,
    input  logic [5:0]  shift,
    output logic out_valid,
    output logic signed [7:0] y
);

    logic [2:0] lat;                                 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lat <= '0;
        else        lat <= {lat[1:0], in_valid};
    end
    assign out_valid = lat[2];

    logic signed [31:0] t;                     
    logic [15:0] M_1;
    logic [5:0]  shift_1;
    always_ff @(posedge clk) begin
        t <= acc + bias;  M_1 <= M;  shift_1 <= shift;
    end

    logic signed [47:0] p;                      
    logic [5:0] shift_2;
    always_ff @(posedge clk) begin
        p <= t * $signed({1'b0, M_1});
        shift_2 <= shift_1;
    end

    logic signed [47:0] r;                         
    assign r = (p + (48'sd1 <<< (shift_2 - 6'd1))) >>> shift_2;
    always_ff @(posedge clk) begin
        if (r[47])           y <= 8'sd0;
        else if (|r[46:7])   y <= 8'sd127;
        else                 y <= {1'b0, r[6:0]};
    end

endmodule