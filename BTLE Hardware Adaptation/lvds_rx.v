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

    // Re-time both halves into rising-edge flops before any logic.  q_fall is captured on the
    // falling edge, so logic between it and a rising-edge flop gets only half a period (7.8 ns
    // at 64 MHz); on the iCE40UP5K the sync-match logic below takes about 20 ns.  Registering
    // both bits together keeps them paired and costs one cycle of latency.
    reg q_rise_r, q_fall_r;
    always @(posedge rxclk) begin
        q_rise_r <= q_rise;
        q_fall_r <= q_fall;
    end

    wire b_rise = q_rise_r ^ INVERT[0];
    wire b_fall = q_fall_r ^ INVERT[0];
    wire [1:0] pair = SWAP_PAIR ? {b_fall, b_rise} : {b_rise, b_fall};

    reg  [31:0] sr;
    wire [31:0] sr_n = {sr[29:0], pair};

    // Timing (64 MHz on the iCE40UP5K leaves room for about 4 LUT levels):
    //   * The window is the registered shift register `win` (one cycle after the pair arrives),
    //     and words are taken from the same window, so framing is unchanged; latency +1 cycle.
    //   * match_r and boundary_r are computed one cycle early from the next-state values, so
    //     match_r == pattern(win) and boundary_r == (cand && cyc == 15) exactly, but both
    //     come straight from flops.
    //   * lock_now / miss_drop compare the counter against LIMIT-1 instead of adding 1 first.
    wire [31:0] win = sr;

    function pattern;
        input [31:0] w;
        begin
            pattern = (w[31:30] == 2'b10) && (w[15:14] == 2'b01) &&
                      (!CHECK_LSB || (!w[16] && !w[0]));
        end
    endfunction

    reg        match_r;      // == pattern(win)
    reg        boundary_r;   // == cand && (cyc == 15)
    reg        cand;
    reg [3:0]  cyc;
    reg [3:0]  ok;
    reg [3:0]  miss;
    reg        locked;
    reg        pend;
    reg        emit_r;

    wire       match     = match_r;
    wire [3:0] ok_n      = ok + 4'd1;
    wire [3:0] miss_n    = miss + 4'd1;
    // ok and miss change only at a candidate start or a boundary, and are next read at the
    // boundary 16 cycles later, so these registered compares (one cycle behind) are exact.
    reg        lock_now;     // == (ok + 1 >= LOCK_WORDS)
    reg        miss_drop;    // == (miss + 1 >= MISS_MAX)
    always @(posedge rxclk) begin
        lock_now  <= (ok >= LOCK_WORDS - 1);
        miss_drop <= (miss >= MISS_MAX - 1);
    end
    wire       boundary  = boundary_r;
    wire       emit      = boundary && match && (locked || lock_now) && !rst;

    // Next-state forms: sr becomes sr_n; cand stays set past a cyc==14 cycle (cand only drops
    // on a boundary) and cyc becomes 15, so boundary next cycle = cand && cyc == 14.
    always @(posedge rxclk) begin
        match_r    <= pattern(sr_n);
        boundary_r <= !rst && cand && (cyc == 4'd14);
    end

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
            if (boundary) begin
                if (match) begin
                    miss <= 4'd0;
                    if (!locked) begin
                        ok <= ok_n;
                        if (lock_now) locked <= 1'b1;
                    end
                end else begin
                    miss <= miss_n;
                    if (!locked || miss_drop) begin
                        cand   <= 1'b0;
                        locked <= 1'b0;
                        ok     <= 4'd0;
                    end
                end
            end
        end

        // emit is registered (emit_r) so its decode does not also drive the 26 data-register
        // enables.  One cycle later the window has shifted by one pair (2 bits), so the same
        // word sits 2 bits higher: I_DATA[13:1] at win[31:19], Q_DATA[13:1] at win[15:3].
        emit_r <= emit;
        if (emit_r) begin
            rx_i     <= win[31:19];
            rx_q     <= win[15:3];
            rx_valid <= 1'b1;
        end

        // hand the word to the bb_clk domain at a slot edge, valid for one bb_clk period
        if (emit_r)    pend <= 1'b1;
        else if (slot) pend <= 1'b0;

        if (slot) begin
            rx_valid_bb <= pend;
            if (pend) begin
                rx_i_bb <= rx_i;
                rx_q_bb <= rx_q;
            end
        end

        if (rst) begin
            emit_r      <= 1'b0;
            pend        <= 1'b0;
            rx_valid_bb <= 1'b0;
        end
    end

endmodule
