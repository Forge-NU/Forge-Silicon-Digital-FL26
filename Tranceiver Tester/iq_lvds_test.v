`default_nettype none
`timescale 1ns/1ps

// =====================================================================
//  AT86RF215 I/Q interface: Option B tone + Step 0 loopback checker
//  Target: iCE40 (UP5K on pico2-ice). Single clock domain = radio RXCLK.
// =====================================================================
//
//  Pin connections (single-ended side of your external LVDS driver/receiver):
//
//    FPGA port      Your pin   Goes to (via LVDS chip)        Direction
//    -------------  ---------  ---------------------------  ---------
//    tx_data_pin    pin 0      radio TXDP/TXDN  (28/27)      FPGA -> radio
//    tx_clk_pin     pin 1      radio TXCLKP/TXCLKN (26/25)   FPGA -> radio
//    rx_data_pin    pin 2      radio RXDP24/RXDN24 (36/35)   radio -> FPGA
//    rx_clk_pin     pin 3      radio RXCLKP/RXCLKN (34/33)   radio -> FPGA
//
//  The radio is the clock master. RXCLK (64 MHz, DDR, 128 Mb/s) only runs
//  once the radio is in TXPREP, TX or RX state, so nothing in this design
//  happens until the Pico puts the radio in TXPREP.
//
//  What this design does:
//   TX : sends a repeating "frame": GAP_WORDS zero words (>= 2.5 us of
//        zeros so the radio can (re)synchronize), then TONE_WORDS I/Q words.
//        The tone words repeat a 4-sample pattern at 4 Msample/s, which is a
//        complex tone at fs/4 = 1 MHz (Option B).
//   RX : with IQIFC0.EXTLB=1 the radio loops TXD back to RXD24. This block
//        finds the word alignment, then checks every returned word against
//        the expected sequence, and drives four status outputs.
//
//  Word format (32 bits, sent MSB first, DDR: 1st bit on rising, 2nd on falling):
//     [31:30]=10  I_SYNC | [29:16] I_DATA | [15:14]=01 Q_SYNC | [13:0] Q_DATA
//     I/Q sample value is in bits [13:1] (13-bit two's complement), bit 0 = 0.
//
//  Tone words, amplitude A = 1024 (13-bit value, quarter scale):
//     n=0: I=+A, Q=0   n=1: I=0, Q=+A   n=2: I=-A, Q=0   n=3: I=0, Q=-A
//
//  Build with yosys/nextpnr:  see the .pcf file and the README note at the end
//  of this file. Define SIM for the behavioral DDR models used by the testbench.
// =====================================================================

module iq_lvds_test #(
    parameter GAP_WORDS  = 16,    // zero words between frames, multiple of 4, >= 10 (2.5 us)
    parameter TONE_WORDS = 256    // tone words per frame, multiple of 4
) (
    input  wire rx_clk_pin,       // pin 3: radio RXCLK (64 MHz)
    input  wire rx_data_pin,      // pin 2: radio RXD24 (loopback data)
    output wire tx_clk_pin,       // pin 1: TXCLK to radio (forwarded RXCLK)
    output wire tx_data_pin,      // pin 0: TXD to radio

    output wire led_clk,          // blinks ~2 Hz while RXCLK is running
    output wire led_lock,         // 1 = word alignment found
    output wire led_ok,           // 1 = >=1024 consecutive good tone words, no errors
    output wire led_err           // pulses ~16 ms after any bad word
);

    // ---------------------------------------------------------------
    // Clock: use the radio's RXCLK as the only clock
    // ---------------------------------------------------------------
    wire clk;
`ifdef SIM
    assign clk = rx_clk_pin;
`else
    // Fabric route into a global clock buffer. If rx_clk_pin sits on a GBIN
    // pad you can use SB_GB_IO instead for a cleaner clock path.
    SB_GB gb_rxclk (.USER_SIGNAL_TO_GLOBAL_BUFFER(rx_clk_pin),
                    .GLOBAL_BUFFER_OUTPUT(clk));
`endif

    // ---------------------------------------------------------------
    // Tone ROM
    // ---------------------------------------------------------------
    function [31:0] tone_word(input [1:0] n);
        case (n)
            2'd0: tone_word = 32'h8800_4000;   // I=+1024, Q=0
            2'd1: tone_word = 32'h8000_4800;   // I=0,     Q=+1024
            2'd2: tone_word = 32'hB800_4000;   // I=-1024, Q=0
            2'd3: tone_word = 32'h8000_7800;   // I=0,     Q=-1024
        endcase
    endfunction

    // ---------------------------------------------------------------
    // TX: frame sequencer + 32-bit serializer, 2 bits per clock (DDR)
    // ---------------------------------------------------------------
    localparam FRAME = GAP_WORDS + TONE_WORDS;
    localparam FW_W  = $clog2(FRAME);

    reg [3:0]       tx_ph = 4'd0;      // 16 clocks per 32-bit word
    reg [31:0]      tx_sr = 32'd0;
    reg [FW_W-1:0]  fw    = {FW_W{1'b0}};   // word index within frame
    reg             tx_d0 = 1'b0;
    reg             tx_d1 = 1'b0;

    // fw only changes once per word (every 16 clocks), so the compares and the
    // word select below can be spread over several registered stages without
    // affecting behavior. This keeps them out of the 64 MHz critical path.
    reg         is_gap_r  = 1'b1;
    reg         fw_last_r = 1'b0;
    reg  [31:0] next_word_r = 32'd0;
    always @(posedge clk) begin
        is_gap_r    <= (fw < GAP_WORDS);
        fw_last_r   <= (fw == FRAME-1);
        // GAP_WORDS is a multiple of 4, so fw[1:0] is the tone index in the tone part
        next_word_r <= is_gap_r ? 32'd0 : tone_word(fw[1:0]);
    end

    always @(posedge clk) begin
        tx_d0 <= tx_sr[31];            // earlier bit  -> rising edge
        tx_d1 <= tx_sr[30];            // later bit    -> falling edge
        tx_ph <= tx_ph + 4'd1;
        if (tx_ph == 4'd15) begin
            tx_sr <= next_word_r;
            fw    <= fw_last_r ? {FW_W{1'b0}} : fw + 1'b1;
        end else begin
            tx_sr <= {tx_sr[29:0], 2'b00};
        end
    end

    ddr_out u_tx_data (.clk(clk), .d0(tx_d0), .d1(tx_d1), .pad(tx_data_pin));
    // TXCLK: same 64 MHz as RXCLK, edge-aligned with the data (see notes below)
    ddr_out u_tx_clk  (.clk(clk), .d0(1'b1),  .d1(1'b0),  .pad(tx_clk_pin));

    // ---------------------------------------------------------------
    // RX: DDR capture, 4 alignment hypotheses, then word checker
    // ---------------------------------------------------------------
    wire rx_b0, rx_b1;
    ddr_in u_rx_data (.clk(clk), .pad(rx_data_pin), .q0(rx_b0), .q1(rx_b1));

    // Two shift registers cover both possible in-pair bit orders. Two taps
    // each cover the two possible word boundaries inside a 2-bit pair.
    reg [32:0] sr_a = 33'd0, sr_b = 33'd0;
    always @(posedge clk) begin
        sr_a <= {sr_a[30:0], rx_b0, rx_b1};
        sr_b <= {sr_b[30:0], rx_b1, rx_b0};
    end
    wire [31:0] wa0 = sr_a[31:0];
    wire [31:0] wa1 = sr_a[32:1];
    wire [31:0] wb0 = sr_b[31:0];
    wire [31:0] wb1 = sr_b[32:1];

    localparam [31:0] W0 = 32'h8800_4000;   // == tone_word(0), first word after a gap

    reg         locked  = 1'b0;
    reg         skip    = 1'b0;     // ignore the one check that lands right after lock
    reg         sel_b   = 1'b0;
    reg         sel_off = 1'b0;
    reg [3:0]   rx_ph   = 4'd0;
    reg [1:0]   exp_idx = 2'd0;
    reg [10:0]  good_cnt = 11'd0;
    reg [19:0]  err_stretch = 20'd0;

    wire [31:0] w_sel = sel_b ? (sel_off ? wb1 : wb0)
                              : (sel_off ? wa1 : wa0);

    // Pipeline (a 32-bit compare does not fit in one 64 MHz clock on the UP5K).
    // Cycle T   : shift registers hold a complete word
    // Cycle T+1 : hit_* (lock search) and w_r (selected word) are registered
    // Cycle T+2 : w_zero / w_exp are registered
    // Decision  : lock search acts at T+1, the per-word check acts at T+2
    reg         hit_a0 = 1'b0, hit_a1 = 1'b0, hit_b0 = 1'b0, hit_b1 = 1'b0;
    reg [31:0]  w_r = 32'd0;
    reg         w_zero = 1'b0, w_exp = 1'b0;

    always @(posedge clk) begin
        hit_a0 <= (wa0 == W0);
        hit_a1 <= (wa1 == W0);
        hit_b0 <= (wb0 == W0);
        hit_b1 <= (wb1 == W0);
        w_r    <= w_sel;
        w_zero <= (w_r == 32'd0);
        w_exp  <= (w_r == tone_word(exp_idx));
    end

    always @(posedge clk) begin
        rx_ph <= rx_ph + 4'd1;
        if (err_stretch != 20'd0) err_stretch <= err_stretch - 1'b1;

        if (!locked) begin
            good_cnt <= 11'd0;
            // Look for the first tone word after a gap at any of the 4 alignments.
            // Lock at T+1; the next word completes at T+16, so its check is at T+18
            // == T+2 (mod 16). rx_ph = 0 at T+2 would check the lock word again, so
            // 'skip' swallows that one.
            if (hit_a0 | hit_a1 | hit_b0 | hit_b1) begin
                locked  <= 1'b1;
                skip    <= 1'b1;
                sel_b   <= hit_b0 | hit_b1;
                sel_off <= (hit_a1 | hit_b1) & ~(hit_a0 | hit_b0);
                rx_ph   <= 4'd0;
                exp_idx <= 2'd1;
            end
        end else if (rx_ph == 4'd0) begin
            if (skip) begin
                skip <= 1'b0;
            end else if (w_zero) begin
                exp_idx <= 2'd0;                        // in the gap; tone restarts at index 0
            end else if (w_exp) begin
                exp_idx <= exp_idx + 2'd1;
                if (good_cnt != 11'h7FF) good_cnt <= good_cnt + 11'd1;
            end else begin
                locked      <= 1'b0;                    // bad word: drop lock, relock at next frame
                err_stretch <= {20{1'b1}};
            end
        end
    end

    // ---------------------------------------------------------------
    // Status outputs (active HIGH; invert in the top level if your LEDs are active low)
    // ---------------------------------------------------------------
    reg [24:0] hb = 25'd0;
    always @(posedge clk) hb <= hb + 1'b1;

    assign led_clk  = hb[24];
    assign led_lock = locked;
    assign led_ok   = good_cnt[10];
    assign led_err  = (err_stretch != 20'd0);

endmodule


// =====================================================================
//  DDR I/O wrappers. SB_IO for the iCE40, behavioral models for SIM.
//  The radio's bit order inside a clock cycle is handled in the checker,
//  so q0/q1 ordering mistakes here cannot break the lock.
// =====================================================================

module ddr_out (input wire clk, input wire d0, input wire d1, output wire pad);
`ifdef SIM
    reg r0 = 1'b0, r1 = 1'b0;
    always @(posedge clk) begin r0 <= d0; r1 <= d1; end
    assign pad = clk ? r0 : r1;      // d0 in the high half, d1 in the low half
`else
    // PIN_TYPE 6'b010000: DDR output (D_OUT_0 on rising edge, D_OUT_1 on falling)
    SB_IO #(.PIN_TYPE(6'b010000), .PULLUP(1'b0)) io (
        .PACKAGE_PIN(pad),
        .OUTPUT_CLK(clk),
        .D_OUT_0(d0),
        .D_OUT_1(d1)
    );
`endif
endmodule

module ddr_in (input wire clk, input wire pad, output wire q0, output wire q1);
`ifdef SIM
    reg r0 = 1'b0, r1 = 1'b0;
    always @(posedge clk) r0 <= pad;
    always @(negedge clk) r1 <= pad;
  `ifdef SIM_SWAP
    assign q0 = r1;                  // force the other in-pair order, to test sr_b
    assign q1 = r0;
  `else
    assign q0 = r0;
    assign q1 = r1;
  `endif
`else
    // PIN_TYPE 6'b000000: registered input; with INPUT_CLK, D_IN_0 = rising
    // edge sample and D_IN_1 = falling edge sample (DDR input)
    SB_IO #(.PIN_TYPE(6'b000000), .PULLUP(1'b0)) io (
        .PACKAGE_PIN(pad),
        .INPUT_CLK(clk),
        .D_IN_0(q0),
        .D_IN_1(q1)
    );
`endif
endmodule

// ---------------------------------------------------------------------
// Notes
//  * TXCLK/TXD phase: both are launched from the same DDR output cells, so
//    TXCLK is edge-aligned with TXD. The datasheet only gives a receiver skew
//    window (Table 10-35: -1..+2 ns data-to-clock) and not the nominal phase.
//    If the radio never reports IQIFC2.SYNC=1, the first thing to try is a
//    TXCLK phase shift of about a quarter clock period (3.9 ns).
//  * RX is sampled with the same RXCLK that launches the data. The radio
//    delays the data ~3.9 ns after the clock edge by default (IQIFC1.SKEWDRV=2,
//    Table 10-34), which puts the opposite clock edge in the middle of the eye.
// ---------------------------------------------------------------------
