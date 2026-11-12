// lvds_rx.v  --  AT86RF215 I/Q receive link: DDR capture, frame lock, word decode
//
// Input is the single-ended RXD24 line from the SN65LVDS049 receiver, with the matching
// RXCLK also from the SN65LVDS049, used as `rxclk`.
//
// Word format (datasheet 4.5.4):
//   [31:30] I_SYNC = 0b10   [29:16] I_DATA[13:0]   [15:14] Q_SYNC = 0b01   [13:0] Q_DATA[13:0]
//   the samples are I_DATA[13:1] and Q_DATA[13:1], 13-bit two's complement; in the receive
//   direction I_DATA[0] and Q_DATA[0] are always 0.
// Bit order (4.5.3, Figure 4-10): the radio's data is centre-aligned to RXCLK, bit 31 on a
// rising edge, bit 30 on a falling edge, and so on.  One clock cycle therefore carries the
// pair {rising-edge bit, falling-edge bit}, and a 32-bit word takes 16 cycles.
//
// Framing: a 32-bit window of the last 16 pairs is checked for the sync pattern (plus the two
// guaranteed-zero bits).  A match starts a candidate; the same pattern must repeat at the
// 16-cycle spacing LOCK_WORDS times in a row to lock.  After lock, MISS_MAX consecutive
// misses drop it.  Only words that match are passed on.  The line idles high when the radio's
// receiver link is off.  VERIFIED (SN65LVDS049 data sheet 8.3.2 and Table 2): an open, shorted or
// terminated input pair with no driver makes the receiver output go high.  A constant 1, or a
// constant 0, never matches.  The 100 ohm termination must be a plain resistor across the pair,
// as on the adapter, so the fail-safe pull-ups still work.
//
// Outputs in the rxclk domain:   rx_i, rx_q, rx_valid (one rxclk cycle per word)
// Outputs for the bb_clk domain: rx_i_bb, rx_q_bb, rx_valid_bb (valid for one full bb_clk
// period, launched mid-period using `slot` from bb_clkgen, see that file)
//
// Algorithm checked against lvds_framing_model.py (3000 random-prefix trials, no false locks).
// NOT SIMULATED OR SYNTHESISED when written.

module lvds_rx #(
    parameter LOCK_WORDS = 3,
    parameter MISS_MAX   = 2,
    parameter CHECK_LSB  = 1,    // also require I_DATA[0] = Q_DATA[0] = 0
    parameter INVERT     = 0,    // 1 if the differential pair is wired swapped
    parameter SWAP_PAIR  = 0     // 1 if bench measurement shows rise/fall order reversed
)(
    input  wire               rxclk,
    input  wire               rst,           // synchronous to rxclk
    input  wire               rxd,           // from the SN65LVDS049 (ROUT2)
    input  wire               slot,          // from bb_clkgen

    output reg  signed [12:0] rx_i,
    output reg  signed [12:0] rx_q,
    output reg                rx_valid,
    output wire               rx_lock,

    output reg  signed [12:0] rx_i_bb,
    output reg  signed [12:0] rx_q_bb,
    output reg                rx_valid_bb
);

    wire q_rise, q_fall;
    ddr_in u_in (.clk(rxclk), .pad(rxd), .q_rise(q_rise), .q_fall(q_fall));

    wire b_rise = q_rise ^ INVERT[0];
    wire b_fall = q_fall ^ INVERT[0];
    wire [1:0] pair = SWAP_PAIR ? {b_fall, b_rise} : {b_rise, b_fall};

    reg  [31:0] sr;
    wire [31:0] sr_n = {sr[29:0], pair};

    wire match = (sr_n[31:30] == 2'b10) &&
                 (sr_n[15:14] == 2'b01) &&
                 (!CHECK_LSB || (!sr_n[16] && !sr_n[0]));

    reg        cand;
    reg [3:0]  cyc;
    reg [3:0]  ok;
    reg [3:0]  miss;
    reg        locked;
    reg        pend;

    wire [3:0] ok_n      = ok + 4'd1;
    wire [3:0] miss_n    = miss + 4'd1;
    wire       lock_now  = (ok_n >= LOCK_WORDS);
    wire       boundary  = cand && (cyc == 4'd15);
    wire       emit      = boundary && match && (locked || lock_now) && !rst;

    assign rx_lock = locked;

    always @(posedge rxclk) begin
        sr       <= sr_n;
        rx_valid <= 1'b0;

        if (rst) begin
            cand   <= 1'b0;
            cyc    <= 4'd0;
            ok     <= 4'd0;
            miss   <= 4'd0;
            locked <= 1'b0;
        end else if (!cand) begin
            if (match) begin
                cand <= 1'b1;
                cyc  <= 4'd0;
                ok   <= 4'd1;
                miss <= 4'd0;
            end
        end else begin
            cyc <= cyc + 4'd1;
            if (cyc == 4'd15) begin
                if (match) begin
                    miss <= 4'd0;
                    if (!locked) begin
                        ok <= ok_n;
                        if (lock_now) locked <= 1'b1;
                    end
                end else begin
                    miss <= miss_n;
                    if (!locked || (miss_n >= MISS_MAX)) begin
                        cand   <= 1'b0;
                        locked <= 1'b0;
                        ok     <= 4'd0;
                    end
                end
            end
        end

        if (emit) begin
            rx_i     <= sr_n[29:17];
            rx_q     <= sr_n[13:1];
            rx_valid <= 1'b1;
        end

        // hand the word to the bb_clk domain at a slot edge, valid for one bb_clk period
        if (emit)      pend <= 1'b1;
        else if (slot) pend <= 1'b0;

        if (slot) begin
            rx_valid_bb <= pend;
            if (pend) begin
                rx_i_bb <= rx_i;
                rx_q_bb <= rx_q;
            end
        end

        if (rst) begin
            pend        <= 1'b0;
            rx_valid_bb <= 1'b0;
        end
    end

endmodule
