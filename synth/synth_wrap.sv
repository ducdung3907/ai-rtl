module synth_wrap #(
    parameter int N = 4
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        serial_in,
    input  logic        valid,
    input  logic        start,
    input  logic        last,
    output logic [31:0] acc_xor,
    output logic        done
);
    logic [2*N*8-1:0]          shift_in;
    logic [N-1:0][7:0]         a_col, b_row;
    logic [N-1:0][N-1:0][31:0] acc;
    logic [N-1:0][31:0]        row_fold, row_fold_q;
    logic [31:0]               fold;

    always_ff @(posedge clk) shift_in <= {shift_in[2*N*8-2:0], serial_in};
    assign a_col = shift_in[N*8-1:0];
    assign b_row = shift_in[2*N*8-1:N*8];

    complete_sa #(.N(N)) dut (
        .clk(clk), .rst_n(rst_n),
        .a_col(a_col), .b_row(b_row),
        .valid(valid), .start(start), .last(last),
        .done(done), .acc(acc)
    );

    // XOR fold in two pipeline stages, so the harness itself never limits
    // the measured clock speed: first each row's N results, then the N rows.
    always_comb begin
        for (int i = 0; i < N; i++) begin
            row_fold[i] = '0;
            for (int j = 0; j < N; j++)
                row_fold[i] = row_fold[i] ^ acc[i][j];
        end
        fold = '0;
        for (int i = 0; i < N; i++)
            fold = fold ^ row_fold_q[i];
    end

    always_ff @(posedge clk) begin
        row_fold_q <= row_fold;   // stage 1: one XOR per row
        acc_xor    <= fold;       // stage 2: XOR of the rows
    end
endmodule