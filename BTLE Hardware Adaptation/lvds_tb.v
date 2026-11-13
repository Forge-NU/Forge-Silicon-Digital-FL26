// lvds_tb.v  --  testbench for bb_clkgen, lvds_rx and lvds_tx with models of the radio
//
//   iverilog -g2005 -o lvds_tb ddr_io.v bb_clkgen.v lvds_rx.v lvds_tx.v lvds_tb.v && vvp lvds_tb
//
// RX side: a model of the radio's I/Q driver sends a random prefix (so word boundaries are
//   not aligned to anything) then 40 words, centre-aligned to RXCLK with the default
//   SKEWDRV delay of 3.906 ns, bit 31 on a rising edge.  Checks: the received words are an
//   exact tail of the sent words, only a few words are lost before lock, the bb_clk-domain
//   copies match, and lock drops when the line goes idle high.
// TX side: a model of the radio's TX-link receiver samples TXD 3.9 ns after every TXCLK edge
//   and checks, per datasheet 4.5.6: no sync without 32 zero bits before it, bit 31 on a rising
//   edge, sync patterns in place, I/Q consistent (q = ~i) and advancing by exactly 4 per word,
//   no data before stream_en, and at least 10 zero words between two bursts even when
//   stream_en is dropped and raised again quickly.
//
// NOT RUN when written.

`timescale 1ns/1ps

module lvds_tb;
    localparam real HALF = 7.8125;           // 64 MHz
    localparam NW   = 40;
    localparam PRE  = 38;                    // even: bit 31 of each word lands on a rising edge
    localparam NBITS = PRE + 32 * NW;
    localparam MIN_IDLE = 10;

    reg rxclk = 1'b0;
    always #(HALF) rxclk = ~rxclk;
    reg rst = 1'b1;

    wire bb_clk, slot;
    bb_clkgen u_clk (.rxclk(rxclk), .rst(rst), .bb_clk(bb_clk), .slot(slot));

    // ------------------------------------------------------------------ RX side
    reg         rxd;
    reg         bits [0:NBITS-1];
    reg  [12:0] sent_i [0:NW-1];
    reg  [12:0] sent_q [0:NW-1];
    reg         started = 1'b0;
    integer     bi, n, k, seed;
    reg  [31:0] w;

    initial begin
        seed = 12345;
        for (n = 0; n < PRE; n = n + 1) bits[n] = $random(seed);
        for (k = 0; k < NW; k = k + 1) begin
            sent_i[k] = $random(seed);
            sent_q[k] = $random(seed);
            w = {2'b10, sent_i[k], 1'b0, 2'b01, sent_q[k], 1'b0};
            for (n = 0; n < 32; n = n + 1) bits[PRE + 32 * k + n] = w[31 - n];
        end
        rxd = bits[0];
        bi  = 1;
        @(negedge rxclk);
        #1 started = 1'b1;
    end

    // each clock edge, the bit that is centred on the NEXT edge starts 3.906 ns from now
    always @(posedge rxclk or negedge rxclk) begin
        if (started) begin
            #3.906;
            rxd = (bi < NBITS) ? bits[bi] : 1'b1;      // idle high after the stream
            bi  = bi + 1;
        end
    end

    wire signed [12:0] rx_i, rx_q, rx_i_bb, rx_q_bb;
    wire               rx_valid, rx_lock, rx_valid_bb;

    lvds_rx u_rx (
        .rxclk(rxclk), .rst(rst), .rxd(rxd), .slot(slot),
        .rx_i(rx_i), .rx_q(rx_q), .rx_valid(rx_valid), .rx_lock(rx_lock),
        .rx_i_bb(rx_i_bb), .rx_q_bb(rx_q_bb), .rx_valid_bb(rx_valid_bb)
    );

    integer     got_n = 0, got_bb = 0;
    reg  [12:0] got_i [0:NW-1];
    reg  [12:0] got_q [0:NW-1];
    reg  [12:0] bb_i  [0:NW-1];
    reg  [12:0] bb_q  [0:NW-1];

    always @(posedge rxclk) begin
        if (rx_valid && got_n < NW) begin
            got_i[got_n] = rx_i;
            got_q[got_n] = rx_q;
            got_n = got_n + 1;
        end
    end
    always @(posedge bb_clk) begin
        if (rx_valid_bb && got_bb < NW) begin
            bb_i[got_bb] = rx_i_bb;
            bb_q[got_bb] = rx_q_bb;
            got_bb = got_bb + 1;
        end
    end

    // ------------------------------------------------------------------ TX side
    reg  signed [12:0] tx_i = 13'sd0;
    reg  signed [12:0] tx_q = -13'sd1;
    reg                stream_en = 1'b0;
    wire               txd, txclk, tx_act;

    always @(posedge bb_clk) begin
        tx_i <= tx_i + 13'sd1;
        tx_q <= ~(tx_i + 13'sd1);
    end

    lvds_tx #(.MIN_IDLE_WORDS(MIN_IDLE)) u_tx (
        .rxclk(rxclk), .rst(rst), .slot(slot),
        .tx_i(tx_i), .tx_q(tx_q), .tx_ctrl(1'b0), .stream_en(stream_en),
        .txd(txd), .txclk(txclk), .tx_data_active(tx_act)
    );

    // model of the radio's TX-link receiver
    integer     zero_run = 0;
    integer     pos = -1;                    // bit index inside the word being received, -1 idle
    reg         back2back = 1'b0;
    reg         cur_b2b   = 1'b0;      // was the word being received back to back with the last?
    reg         edge_rising = 1'b0;
    reg  [31:0] rw;
    integer     words_ok = 0, tx_errors = 0, sync_no_zeros = 0, data_before_en = 0;
    integer     burst_gap = 0;
    integer     prev_i = -1;
    reg         in_burst = 1'b0;
    reg         ever_en = 1'b0;
    reg  [12:0] wi, wq;

    always @(posedge stream_en) ever_en = 1'b1;

    task start_word;
        begin
            if (!edge_rising) begin
                tx_errors = tx_errors + 1;
                $display("FAIL: bit 31 not sampled after a rising TXCLK edge at %0t", $time);
            end
            if (!back2back && zero_run < 32) begin
                sync_no_zeros = sync_no_zeros + 1;
                $display("FAIL: I_SYNC without 32 zero bits before it at %0t", $time);
            end
            cur_b2b = back2back;
            if (!back2back) burst_gap = zero_run;
            pos = 1;
            rw = 32'd0;
            rw[31] = 1'b1;
        end
    endtask

    task finish_word;
        begin
            wi = rw[29:17];
            wq = rw[13:1];
            if (rw[31:30] != 2'b10 || rw[15:14] != 2'b01 || rw[16] != 1'b0 || rw[0] != 1'b0) begin
                tx_errors = tx_errors + 1;
                $display("FAIL: bad sync/control bits in word %h at %0t", rw, $time);
            end
            if (wq != ~wi) begin
                tx_errors = tx_errors + 1;
                $display("FAIL: I/Q not a consistent pair: i=%h q=%h at %0t", wi, wq, $time);
            end
            if (!ever_en) data_before_en = data_before_en + 1;
            if (cur_b2b && prev_i >= 0 && wi != ((prev_i + 4) & 13'h1FFF)) begin
                tx_errors = tx_errors + 1;
                $display("FAIL: I advanced %0d instead of 4 at %0t", (wi - prev_i) & 13'h1FFF, $time);
            end
            if (!cur_b2b && prev_i >= 0 && burst_gap < 32 * MIN_IDLE) begin
                tx_errors = tx_errors + 1;
                $display("FAIL: only %0d zero bits between bursts, need %0d, at %0t",
                         burst_gap, 32 * MIN_IDLE, $time);
            end
            prev_i   = wi;
            words_ok = words_ok + 1;
        end
    endtask

    always @(txclk) begin
        if (txclk === 1'b0 || txclk === 1'b1) begin
            edge_rising = txclk;
            #3.9;
            if (txd === 1'b0 || txd === 1'b1) begin
                if (pos < 0) begin
                    if (txd === 1'b1 && (zero_run >= 32 || back2back)) begin
                        start_word;
                        back2back = 1'b0;
                    end else if (txd === 1'b1) begin
                        sync_no_zeros = sync_no_zeros + 1;
                        $display("FAIL: stray 1 on an idle line at %0t", $time);
                        zero_run = 0;
                    end else begin
                        zero_run  = back2back ? 1 : zero_run + 1;
                        back2back = 1'b0;
                    end
                end else begin
                    rw[31 - pos] = txd;
                    pos = pos + 1;
                    if (pos == 32) begin
                        finish_word;
                        pos       = -1;
                        back2back = 1'b1;
                        zero_run  = 0;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------ control and checks
    integer errors = 0;
    integer lost, j;

    task check;
        input cond;
        input [255:0] msg;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    initial begin
        #50 rst = 1'b0;
        #2000 stream_en = 1'b1;             // burst 1
        #8000 stream_en = 1'b0;
        #1000 stream_en = 1'b1;             // burst 2, requested too soon: must be held off
        #8000 stream_en = 1'b0;
        #4000;

        // RX checks
        lost = NW - got_n;
        check(got_n > 0,                 "no words received");
        check(lost >= 1 && lost <= 6,    "unexpected number of words lost before lock");
        for (j = 0; j < got_n; j = j + 1) begin
            if (got_i[j] !== sent_i[lost + j] || got_q[j] !== sent_q[lost + j]) begin
                errors = errors + 1;
                $display("FAIL: rx word %0d mismatch: got %h/%h expected %h/%h", j,
                         got_i[j], got_q[j], sent_i[lost + j], sent_q[lost + j]);
            end
        end
        check(got_bb == got_n,           "bb_clk copy has a different word count");
        for (j = 0; j < got_bb && j < got_n; j = j + 1) begin
            if (bb_i[j] !== got_i[j] || bb_q[j] !== got_q[j]) begin
                errors = errors + 1;
                $display("FAIL: bb_clk copy of word %0d differs", j);
            end
        end
        check(rx_lock == 1'b0,           "lock not dropped after the line went idle");

        // TX checks
        check(words_ok > 40,             "too few TX data words seen by the radio model");
        check(tx_errors == 0,            "TX link errors");
        check(sync_no_zeros == 0,        "sync without zero bits");
        check(data_before_en == 0,       "data words before stream_en");

        if (errors == 0) $display("PASS: rx words %0d (lost %0d), tx words %0d", got_n, lost, words_ok);
        else             $display("FAILED: %0d error(s)", errors);
        $finish;
    end
endmodule
