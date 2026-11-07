`timescale 1ns/1ps

// Self-checking testbench for frame_rx (the v3 frame parser).
//
// Frame:  START(0xA6) seq payload(4 * N_STEPS bytes, each 0..127) checksum(sum of payload mod 128)
// Rules:  a byte with the top bit set inside a frame abandons it (and starts a new frame if it is START);
//         a checksum mismatch gives frame_err; bytes outside a frame (not START) are ignored.
//
// The testbench contains a behavioural model of those rules (tb_model_feed). Every byte stream sent to the DUT
// is also fed to the model, which predicts: frame_ok / frame_err events with their seq, the RAM contents after
// every good frame, the number of abandoned frames, and the number of RAM word writes. The DUT must match.
//
// Streams: good frames (seq 0, 127, random), bad checksum, corrupted payload byte, dropped byte, extra byte,
// stray top-bit byte, junk between frames, truncated frame followed by a new one, and random fuzzing that mixes
// all of these. Bytes come back to back or with random gaps.
//
// Run:
//   iverilog -g2012 -o sim.vvp board/frame_rx.sv tb/tb_frame_rx.sv -s tb_frame_rx && vvp sim.vvp
//   iverilog ... -Ptb_frame_rx.N_STEPS=16 ...      vvp sim.vvp +seed=3

module tb_frame_rx;
    parameter int N_STEPS = 784;
    parameter int N_FUZZ  = 60;

    localparam int AW   = $clog2(N_STEPS);
    localparam int PLEN = 4 * N_STEPS;
    localparam logic [7:0] START = 8'hA6;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic rx_valid = 0;
    logic [7:0] rx_data = 0;
    logic ram_we;
    logic [AW-1:0] ram_waddr;
    logic [31:0] ram_wdata;
    logic frame_ok, frame_err, frame_abort;
    logic [6:0] frame_seq;

    frame_rx #(.N_STEPS(N_STEPS)) dut (.*);

    int errors = 0;
    task automatic fail(input string msg);
        errors++;
        if (errors <= 15) $display("FAIL @%0t: %s", $time, msg);
    endtask

    // ---------------- DUT-side bookkeeping
    logic [31:0] tb_ram [0:N_STEPS-1];
    int n_we = 0, n_abort = 0, n_ok = 0, n_err = 0;

    // ---------------- behavioural model of the rules
    int m_state = 0;            // 0 WAIT_START, 1 SEQ, 2 PAYLOAD, 3 CHECK
    int m_seq = 0, m_sum = 0, m_cnt = 0;
    logic [7:0] m_bytes [0:PLEN-1];
    int exp_abort = 0, exp_words = 0;
    int ev_kind [$];            // 1 = ok, 2 = err
    int ev_seq  [$];
    logic [31:0] exp_ram_q [$]; // N_STEPS words per good frame, in order

    task automatic tb_model_feed(input logic [7:0] b);
        if (m_state != 0 && b[7]) begin
            exp_abort++;
            m_state = (b == START) ? 1 : 0;
        end else begin
            case (m_state)
                0: if (b == START) m_state = 1;
                1: begin m_seq = b[6:0]; m_sum = 0; m_cnt = 0; m_state = 2; end
                2: begin
                    m_bytes[m_cnt] = b;
                    m_sum = (m_sum + b[6:0]) & 127;
                    m_cnt++;
                    if (m_cnt % 4 == 0) exp_words++;
                    if (m_cnt == PLEN) m_state = 3;
                end
                3: begin
                    m_state = 0;
                    ev_seq.push_back(m_seq);
                    if (b[6:0] == m_sum) begin
                        ev_kind.push_back(1);
                        for (int k = 0; k < N_STEPS; k++)
                            exp_ram_q.push_back({m_bytes[4*k+3], m_bytes[4*k+2], m_bytes[4*k+1], m_bytes[4*k]});
                    end else ev_kind.push_back(2);
                end
            endcase
        end
    endtask

    // ---------------- driver: byte queue -> rx_valid / rx_data
    logic [7:0] send_q [$];
    int gap_pct = 0;
    always @(negedge clk) begin
        rx_valid = 0;
        rx_data  = $urandom;                              // junk while rx_valid is low
        if (rst_n && send_q.size() > 0 && ($urandom_range(0, 99) >= gap_pct)) begin
            rx_valid = 1;
            rx_data  = send_q.pop_front();
        end
    end

    logic [7:0] st [$];                // staging queue: build a byte sequence here, then send_st()
    task automatic send_st();
        for (int i = 0; i < st.size(); i++) begin
            send_q.push_back(st[i]);
            tb_model_feed(st[i]);
        end
    endtask

    // ---------------- monitor
    logic [31:0] w_exp;
    int ram_bad, k, s;
    always @(posedge clk) if (rst_n) begin
        if (ram_we) begin tb_ram[ram_waddr] = ram_wdata; n_we++; end
        if (frame_abort) n_abort++;
        if (frame_ok && frame_err) fail("frame_ok and frame_err in the same cycle");
        if (frame_ok || frame_err) begin
            if (ev_kind.size() == 0) fail("unexpected frame event");
            else begin
                k = ev_kind.pop_front(); s = ev_seq.pop_front();
                if (frame_ok)  n_ok++;
                if (frame_err) n_err++;
                if ((frame_ok ? 1 : 2) != k) fail($sformatf("event is %s, expected %s", frame_ok ? "ok" : "err", k == 1 ? "ok" : "err"));
                if (frame_seq !== s[6:0])    fail($sformatf("frame_seq = %0d, expected %0d", frame_seq, s));
                if (frame_ok && k == 1) begin
                    ram_bad = 0;
                    for (int a = 0; a < N_STEPS; a++) begin
                        w_exp = exp_ram_q.pop_front();
                        if (!ram_bad && tb_ram[a] !== w_exp) begin
                            ram_bad = 1;
                            fail($sformatf("RAM[%0d] = %08h, expected %08h", a, tb_ram[a], w_exp));
                        end
                    end
                end
            end
        end
    end

    // ---------------- frame builders
    int mf_sum;
    logic [7:0] mf_b;
    task automatic make_frame(input int seq);          // fills st with a good frame
        st = {};
        st.push_back(START);
        st.push_back(seq[7:0]);
        mf_sum = 0;
        for (int i = 0; i < PLEN; i++) begin
            mf_b = $urandom_range(0, 127);
            st.push_back(mf_b);
            mf_sum = (mf_sum + mf_b) & 127;
        end
        st.push_back(mf_sum[7:0]);
    endtask

    logic [7:0] part [$];

    task automatic drain(input string label);
        int t = 0;
        while ((send_q.size() > 0) && t < 5_000_000) begin @(negedge clk); t++; end
        repeat (10) @(negedge clk);
        if (ev_kind.size() != 0) fail($sformatf("[%s] %0d frame events missing", label, ev_kind.size()));
        if (n_abort != exp_abort) fail($sformatf("[%s] frame_abort count %0d, expected %0d", label, n_abort, exp_abort));
        if (n_we != exp_words)    fail($sformatf("[%s] %0d RAM writes, expected %0d", label, n_we, exp_words));
        if (errors == 0) $display("  %-36s ok  (frames ok/err so far %0d/%0d, aborts %0d)", label, n_ok, n_err, n_abort);
        else begin $display("FAIL: stopping after [%s], %0d errors", label, errors); $finish; end
    endtask

    int seed, pos, mode;
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        $display("tb_frame_rx: N_STEPS = %0d, seed = %0d", N_STEPS, seed);
        void'($urandom(seed));
        for (int i = 0; i < N_STEPS; i++) tb_ram[i] = 'x;

        repeat (3) @(negedge clk);
        if (frame_ok !== 0 || frame_err !== 0 || frame_abort !== 0 || ram_we !== 0) fail("outputs not 0 in reset");
        rst_n = 1;
        repeat (3) @(negedge clk);

        // 1. good frames, back to back and with gaps, seq at both ends of its range
        gap_pct = 0;
        make_frame(0);   send_st();
        make_frame(127); send_st();
        make_frame(55);  send_st();
        drain("good frames, back to back");
        gap_pct = 40;
        make_frame(1);   send_st();
        make_frame(2);   send_st();
        drain("good frames, with gaps");

        // 2. bad checksum / corrupted payload byte
        gap_pct = 10;
        make_frame(7);  st[st.size()-1] = (st[st.size()-1] + 1) & 127;  send_st();
        make_frame(8);  st[2 + PLEN/2] = (st[2 + PLEN/2] + 1) & 127;    send_st();
        make_frame(9);  send_st();                                  // a good one afterwards
        // every bit of the checksum must matter: flip each of its 7 bits in turn
        for (int cb = 0; cb < 7; cb++) begin
            make_frame(40 + cb);  st[st.size()-1] = st[st.size()-1] ^ (8'h01 << cb);  send_st();
        end
        make_frame(50); send_st();
        drain("bad checksum, corrupted byte");

        // 3. junk before and between frames (including top-bit bytes that are not START)
        gap_pct = 0;
        st = {8'h00, 8'h55, 8'h7F, 8'hA5, 8'hFF, 8'h12, 8'hA7}; send_st();
        make_frame(10); send_st();
        st = {8'h33, 8'hC3, 8'h00}; send_st();
        make_frame(11); send_st();
        drain("junk before and between frames");

        // 4. dropped payload byte: abandoned by the next START
        make_frame(20); st.delete(2 + PLEN/3);  send_st();
        make_frame(21); send_st();
        drain("dropped byte, next frame resyncs");

        // 5. extra byte
        make_frame(22); st.insert(2 + PLEN/3, 8'h17);  send_st();
        make_frame(23); send_st();
        drain("extra byte");

        // 6. stray top-bit byte inside the payload (not START), and START inside the payload
        make_frame(24); st[2 + PLEN/4] = 8'hC3;  send_st();
        make_frame(25); send_st();
        make_frame(26); st[2 + PLEN/3] = START;  send_st();       // frame restarts from the stray START
        make_frame(27); send_st();
        drain("stray top-bit byte, START inside frame");

        // 7. truncated frames, then a good one
        for (int cut = 0; cut < 4; cut++) begin
            make_frame(30);
            part = st;                          // cut a copy of a frame short: prefix of 1 + cut * PLEN/4 bytes
            st = {};
            for (int i = 0; i < 1 + cut * (PLEN / 4); i++) st.push_back(part[i]);
            send_st();
        end
        make_frame(31); send_st();
        drain("truncated frames");

        // 8. fuzz: random mutations, random junk, random gaps
        for (int n = 0; n < N_FUZZ; n++) begin
            gap_pct = (n % 3 == 0) ? 0 : 30;
            make_frame($urandom_range(0, 127));
            mode = $urandom_range(0, 9);
            pos  = 2 + $urandom_range(0, PLEN - 1);
            case (mode)
                0: st.delete(pos);
                1: st.insert(pos, 8'($urandom));
                2: st[pos] = $urandom;                               // any value, may be top-bit
                3: st[st.size()-1] = $urandom;                       // random checksum byte
                4: begin repeat ($urandom_range(1, 5)) void'(st.pop_back()); end   // truncated
                5: st[pos] = (st[pos] + 1) & 127;                    // plain corruption
                default: ;                                           // untouched
            endcase
            if ($urandom_range(0, 3) == 0) begin
                part = st;
                st = {}; repeat ($urandom_range(1, 4)) st.push_back(8'($urandom));
                send_st();
                st = part;
            end
            send_st();
        end
        make_frame(99); send_st();          // closing good frame flushes any half-open frame
        drain("fuzz");

        if (n_ok < 10 || n_err < 3 || n_abort < 5) fail($sformatf("coverage: ok %0d err %0d abort %0d", n_ok, n_err, n_abort));
        if (errors == 0) $display("PASS: %0d good frames, %0d checksum errors, %0d abandoned frames, %0d RAM writes (N_STEPS = %0d)",
                                  n_ok, n_err, n_abort, n_we, N_STEPS);
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule