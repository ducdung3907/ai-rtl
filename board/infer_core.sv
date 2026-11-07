module infer_core #(
    parameter int N = 4,
    parameter int MAC_LAT = 2,
    parameter W_FILE = "weights.mem", 
    parameter B1_FILE = "bias1.mem", 
    parameter B2_FILE = "bias2.mem"
)(
    input logic clk,
    input logic rst_n,

    input logic in_we,
    input logic [$clog2(784)-1:0] in_waddr,
    input logic [31:0] in_wdata,

    input logic start,
    input logic [6:0] start_seq,

    output logic busy,
    output logic done,
    output logic [6:0] done_seq,
    output logic [N-1:0][3:0] digits
);

    `include "model_params.svh"

    typedef enum logic [2:0] {
        IDLE,
        RUN,
        WAIT_DONE,
        EPI,
        DRAIN,
        FINISH
    }state_t;

    state_t state;

    logic layer;                       
    logic [3:0] tile;
    logic [$clog2(L1_K)-1:0] k;                            
    logic [$clog2(ROM_DEPTH)-1:0] w_addr;       
    logic [1:0] j;                             
    logic [6:0] seq;
    logic [6:0] hid_wptr;                      
    logic fin;                        
    logic [N-1:0] am_ov;     

    //mem
    logic [31:0] in_rdata, hid_rdata, w_rdata, b1_rdata, b2_rdata;
    
    logic hid_we;
    logic [31:0] hid_wdata;

    simple_dp_ram #(.WIDTH(32),.DEPTH(L1_K)
    )u_in_ram(
        .clk(clk),
        .we(in_we),
        .waddr(in_waddr),
        .wdata(in_wdata),
        .raddr(k),
        .rdata(in_rdata)
    );

    simple_dp_ram #(.WIDTH(32),.DEPTH(L2_K)
    )u_hid_ram(
        .clk(clk),
        .we(hid_we),
        .waddr(hid_wptr[5:0]),
        .wdata(hid_wdata),
        .raddr(k[$clog2(L2_K)-1:0]),
        .rdata(hid_rdata)
    );

    weight_rom #(.WIDTH(32),.DEPTH(ROM_DEPTH),
    .INIT_FILE(W_FILE)
    )u_w_rom(
        .clk(clk),
        .addr(w_addr),
        .dout(w_rdata)
    );

    weight_rom #(.WIDTH(32),.DEPTH(L2_K),
    .INIT_FILE(B1_FILE)
    )u_b1_rom(
        .clk(clk),
        .addr({tile, j}),                       //same as *4 + j
        .dout(b1_rdata)
    );

    weight_rom #(.WIDTH(32),.DEPTH(12),         //12 is padding from 10 output
    .INIT_FILE(B2_FILE)
    )u_b2_rom(
        .clk(clk),
        .addr({tile[1:0], j}),
        .dout(b2_rdata)
    );

    //array, calc (in or hid)@w
    logic [N-1:0][7:0] a_col, b_row;
    logic valid, sa_start, last, sa_done;
    logic [N-1:0][N-1:0][31:0] acc;

    assign a_col = (layer) ? hid_rdata : in_rdata;
    assign b_row = w_rdata;

    complete_sa #(.N(N),.MAC_LAT(MAC_LAT)
    )u_sa(
        .clk(clk),
        .rst_n(rst_n),
        .a_col(a_col),
        .b_row(b_row),
        .valid(valid),
        .start(sa_start),
        .last(last),
        .done(sa_done),
        .acc(acc)
    );
    
    logic [9:0] k_last;
    assign k_last = layer ? 10'(L2_K - 1) : 10'(L1_K - 1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            layer <= 1'b0; 
            tile <= '0; 
            k <= '0; 
            w_addr <= '0; 
            j <= '0;
            seq <= '0; 
            hid_wptr <= '0; 
            fin <= 1'b0;
            valid <= 1'b0; 
            sa_start <= 1'b0; 
            last <= 1'b0;
        end else begin
            valid <= 1'b0; 
            sa_start <= 1'b0; 
            last <= 1'b0;
            if (hid_we) hid_wptr <= hid_wptr + 1'b1;
            if (am_ov[0]) fin <= 1'b1;
    
            case (state)
                IDLE: if (start) begin
                    seq <= start_seq;
                    layer <= 1'b0; 
                    tile <= '0; 
                    k <= '0; 
                    w_addr <= '0;
                    hid_wptr <= '0; 
                    fin <= 1'b0;
                    state <= RUN;
                end
    
                RUN: begin
                    valid <= 1'b1;
                    sa_start <= (k == 0);
                    last <= (k == k_last);
                    k <= k + 1'b1;
                    w_addr <= w_addr + 1'b1;
                    if (k == k_last) begin
                        k <= '0;
                        state <= WAIT_DONE;
                    end
                end
    
                WAIT_DONE: if (sa_done) begin
                    j <= '0;
                    state <= EPI;
                end
    
                EPI: begin
                    j <= j + 1'b1;
                    if (j == 2'd3) begin
                        if (!layer) begin
                            if (tile == 4'(L1_TILES - 1)) begin
                                state <= DRAIN;
                            end else begin 
                                tile <= tile + 1'b1; 
                                state <= RUN; 
                            end
                        end else begin
                            if (tile == 4'(L2_TILES - 1)) begin
                                state <= FINISH;
                            end else begin 
                                tile <= tile + 1'b1; 
                                state <= RUN; 
                            end
                        end
                    end
                end
    
                DRAIN: if (hid_wptr == 7'd64) begin
                    layer <= 1'b1; tile <= '0; k <= '0;
                    state <= RUN;
                end
    
                FINISH: if (fin) state <= IDLE;
    
                default: state <= IDLE;
            endcase
        end
    end

    assign busy = (state != IDLE);

    logic epi_v, epi_ok, epi_last;
    logic [1:0] epi_j;
    logic [5:0] neuron;
    assign neuron = {tile, j};
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            epi_v <= 1'b0; 
            epi_ok <= 1'b0; 
            epi_last <= 1'b0; 
            epi_j <= '0;
        end else begin
            epi_v <= (state == EPI);
            epi_j <= j;
            epi_ok <= !layer || (neuron < 6'd10);
            epi_last <= layer && (neuron == 6'd9);
        end
    end

    logic [N-1:0][31:0] col;
    for (genvar i = 0; i < N; i++) begin : g_col
        assign col[i] = acc[i][epi_j];
    end
     
    logic [N-1:0] rq_ov;
    logic signed [7:0] rq_y [N];
    
    for (genvar i = 0; i < N; i++) begin : g_lane
        requant u_rq (
            .clk(clk), 
            .rst_n(rst_n),
            .in_valid(epi_v && !layer),
            .acc(col[i]), 
            .bias(b1_rdata),
            .M(L1_M), 
            .shift(6'(L1_SHIFT)),
            .out_valid(rq_ov[i]), 
            .y(rq_y[i])
        );
    end
    
    assign hid_we = rq_ov[0];
    assign hid_wdata = {rq_y[3], rq_y[2], rq_y[1], rq_y[0]};
    
    logic am_valid, am_last;
    logic signed [N-1:0][31:0] am_data;
    logic [N-1:0][3:0] am_idx;
    logic signed [31:0] b2_s;
    assign b2_s = b2_rdata;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            am_valid <= 1'b0; am_last <= 1'b0; am_data <= '0;
        end else begin
            am_valid <= epi_v && layer && epi_ok;
            am_last  <= epi_last;
            for (int i = 0; i < N; i++) am_data[i] <= $signed(col[i]) + b2_s;
        end
    end
    
    for (genvar i = 0; i < N; i++) begin : g_am
        argmax #(.WIDTH(10)) u_am (
            .clk(clk), 
            .rst_n(rst_n),
            .in_valid(am_valid), 
            .in_data(am_data[i]), 
            .in_last(am_last),
            .out_valid(am_ov[i]), 
            .out_max(), 
            .out_index(am_idx[i])
        );
    end
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0; digits <= '0; done_seq <= '0;
        end else begin
            done <= 1'b0;
            if (am_ov[0]) begin
                digits   <= am_idx;
                done_seq <= seq;
                done     <= 1'b1;
            end
        end
    end    
endmodule