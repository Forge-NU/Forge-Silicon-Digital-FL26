// msk_modulator.v  --  whitened bit stream in, 4 Msps I/Q out, plain MSK (no Gaussian filter)
//
// Replaces bit_repeat_upsample + gauss_filter + vco.  At 4 samples per symbol an MSK
// signal (modulation index 0.5, +/-250 kHz at 1 Msym/s) turns the carrier by exactly
// +/-22.5 degrees per sample, so the whole modulator is a 4-bit phase counter that steps
// up or down by one and a 16-entry sine/cosine table.
//
// Timing: it runs on bb_clk (16 MHz).  Bits arrive one per 16 clocks (bit_valid).  Samples
// are produced on the bit_valid clock and every 4 clocks after it, so four per bit, locked to
// the bit stream.  Each sample is held for 4 clocks, which is what lvds_tx expects (one
// sample per 16-rxclk word, captured at `slot`).
//
// After the last data bit it keeps producing samples for PAD_SAMPLES samples so the radio's
// PA has a non-zero signal while it ramps down (datasheet 6.1.4: "add padding samples").
// Then the output returns to zero.  Outputs are zero whenever nothing is being sent.
//
// Pulses:  data_done  after the 4th sample of the last data bit (padding starts)
//          done       one sample period after the last padding sample (output is zero again)
//
// Sign: with FREQ_SIGN = 0 a 1 bit rotates the phasor counter-clockwise (I = cos, Q = sin),
// which is a positive frequency, the BLE convention and the one the repo's demodulator
// expects (sign of i0*q1 - i1*q0).  Whether the radio's I/Q interface maps that to a
// positive RF offset is NOT verified; see FREQ_SIGN below.
//
// Algorithm checked against btle_tx_check.py.  NOT SIMULATED OR SYNTHESISED when written.

module msk_modulator #(
    // Peak sample value is 4095 >> AMP_SHIFT (13-bit signed, so 4095 is full scale).
    // 1 = half scale.  UNCHECKED: leaves headroom for overshoot in the radio's TX
    // interpolation filters.  Lower it (2, 3) if the transmitted spectrum shows clipping
    // products; raise it to 0 for the most output power per PAC setting.
    parameter [2:0]   AMP_SHIFT   = 3'd1,

    // 0: bit 1 = counter-clockwise (positive frequency).  1: reversed.  UNCHECKED: if a
    // phone or sniffer cannot decode the transmitted packet but the spectrum looks right,
    // the radio's I/Q interface may be mirroring the spectrum.  Set this to 1 and retry.
    parameter         FREQ_SIGN   = 0,

    // What to send after the last bit while the PA ramps down.
    // 0: keep the last bit's frequency (a constant +/-250 kHz tone).
    // 1: alternate 4-sample runs of opposite frequency, which averages to no offset.
    // UNCHECKED.  1 is spectrally tidier; use 0 if you want the simplest behaviour.
    parameter         PAD_MODE    = 1,

    // Number of padding samples (4 per microsecond).  Must cover the SPI time for the
    // TXPREP command plus the PA ramp time (TXCUTC.PARAMP, 4 to 32 us) plus margin.
    // UNCHECKED estimate: 96 samples = 24 us covers PARAMP = 4 us with a 3 MHz SPI clock.
    // Raise it if you lengthen PARAMP or slow the SPI clock.
    parameter integer PAD_SAMPLES = 96,

    // Starting phase in 22.5-degree steps.  Irrelevant to decoding.  Change only to
    // inspect different starting points on a scope.
    parameter [3:0]   PHASE_INIT  = 4'd0
)(
    input  wire               clk,        // bb_clk
    input  wire               rst,
    input  wire               bit_in,
    input  wire               bit_valid,  // one clock, one per 16 clocks
    input  wire               bit_last,   // with the last bit

    output reg  signed [12:0] i_out,
    output reg  signed [12:0] q_out,
    output reg                data_done,
    output reg                done,
    output reg                active
);

    // 16-point table, cos in the high half and sin in the low half, 22.5 degrees per step,
    // peak 4095:   cos = 4095, 3783, 2896, 1567, 0, -1567, ...   sin likewise shifted by 90 degrees
    function [25:0] rom_iq;
        input [3:0] k;
        begin
            case (k)
                4'd0:  rom_iq = {13'sd4095,  13'sd0};
                4'd1:  rom_iq = {13'sd3783,  13'sd1567};
                4'd2:  rom_iq = {13'sd2896,  13'sd2896};
                4'd3:  rom_iq = {13'sd1567,  13'sd3783};
                4'd4:  rom_iq = {13'sd0,     13'sd4095};
                4'd5:  rom_iq = {-13'sd1567, 13'sd3783};
                4'd6:  rom_iq = {-13'sd2896, 13'sd2896};
                4'd7:  rom_iq = {-13'sd3783, 13'sd1567};
                4'd8:  rom_iq = {-13'sd4095, 13'sd0};
                4'd9:  rom_iq = {-13'sd3783, -13'sd1567};
                4'd10: rom_iq = {-13'sd2896, -13'sd2896};
                4'd11: rom_iq = {-13'sd1567, -13'sd3783};
                4'd12: rom_iq = {13'sd0,     -13'sd4095};
                4'd13: rom_iq = {13'sd1567,  -13'sd3783};
                4'd14: rom_iq = {13'sd2896,  -13'sd2896};
                default: rom_iq = {13'sd3783, -13'sd1567};
            endcase
        end
    endfunction

    localparam [1:0] S_IDLE = 2'd0,
                     S_DATA = 2'd1,
                     S_PAD  = 2'd2;

    reg [1:0]  st;
    reg [3:0]  ph;
    reg [1:0]  sc;        // clocks since the last sample, event at 3
    reg [2:0]  ne;        // samples produced for the current bit, 0..4
    reg        dir;       // direction of the current bit (1 = up)
    reg        last_r;
    reg [15:0] pc;        // padding samples produced

    wire dir_data = bit_valid ? bit_in : dir;
    wire dir_pad  = PAD_MODE ? (~dir ^ pc[2]) : dir;
    wire dir_ev   = (st == S_PAD) ? dir_pad : dir_data;
    wire step_up  = dir_ev ^ FREQ_SIGN[0];
    wire [3:0] ph_n = step_up ? (ph + 4'd1) : (ph - 4'd1);

    wire [25:0] rom_n = rom_iq(ph_n);
    wire signed [12:0] ri = rom_n[25:13];
    wire signed [12:0] rq = rom_n[12:0];
    wire signed [12:0] si = ri >>> AMP_SHIFT;
    wire signed [12:0] sq = rq >>> AMP_SHIFT;

    always @(posedge clk) begin
        data_done <= 1'b0;
        done      <= 1'b0;

        if (rst) begin
            st     <= S_IDLE;
            ph     <= PHASE_INIT;
            sc     <= 2'd0;
            ne     <= 3'd0;
            dir    <= 1'b0;
            last_r <= 1'b0;
            pc     <= 16'd0;
            i_out  <= 13'sd0;
            q_out  <= 13'sd0;
            active <= 1'b0;
        end else begin
            sc <= sc + 2'd1;

            case (st)
                S_IDLE: begin
                    if (bit_valid) begin
                        st     <= S_DATA;
                        active <= 1'b1;
                        dir    <= bit_in;
                        last_r <= bit_last;
                        ne     <= 3'd1;
                        sc     <= 2'd0;
                        ph     <= ph_n;
                        i_out  <= si;
                        q_out  <= sq;
                    end
                end

                S_DATA: begin
                    if (bit_valid) begin
                        dir    <= bit_in;
                        last_r <= bit_last;
                        ne     <= 3'd1;
                        sc     <= 2'd0;
                        ph     <= ph_n;
                        i_out  <= si;
                        q_out  <= sq;
                    end else if (sc == 2'd3) begin
                        sc <= 2'd0;
                        if (ne != 3'd4) begin
                            ph    <= ph_n;
                            i_out <= si;
                            q_out <= sq;
                            ne    <= ne + 3'd1;
                            if (ne == 3'd3 && last_r) begin
                                data_done <= 1'b1;
                                st        <= S_PAD;
                                pc        <= 16'd0;
                            end
                        end
                    end
                end

                S_PAD: begin
                    if (sc == 2'd3) begin
                        sc <= 2'd0;
                        if (pc < PAD_SAMPLES) begin
                            ph    <= ph_n;
                            i_out <= si;
                            q_out <= sq;
                            pc    <= pc + 16'd1;
                        end else begin
                            i_out  <= 13'sd0;
                            q_out  <= 13'sd0;
                            st     <= S_IDLE;
                            active <= 1'b0;
                            done   <= 1'b1;
                            ph     <= PHASE_INIT;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
