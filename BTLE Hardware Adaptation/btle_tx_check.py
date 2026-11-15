#!/usr/bin/env python3
"""
Checks the TX chain algorithms behind btle_tx_min.v and msk_modulator.v.

  1. an independent reference encoder reproduces the repo's README example
  2. a cycle-level mirror of btle_tx_min (same indices and LFSR updates as the Verilog)
     matches the reference for random packets, channels, access addresses and CRC seeds
  3. a cycle-level mirror of msk_modulator: ROM accuracy, 4 samples per bit at a 4-clock
     cadence, phase step +/-22.5 deg, padding, pulse timing, and that the repo's own
     demodulator rule  sign(i0*q1 - i1*q0)  recovers the bits from the samples
  4. writes btle_tx_tb.v with the expected bit stream for the default packet embedded

It checks the algorithms, not the Verilog.  Keep it in step with the HDL.
"""
import math
import random

# ---------------------------------------------------------------- reference encoder
def bits_lsb(data):
    return [(b >> i) & 1 for b in data for i in range(8)]


def ref_whiten(nbits, ch):
    s = [1] + [(ch >> (5 - k)) & 1 for k in range(6)]          # pos0=1, pos1..6 = channel MSB first
    out = []
    for _ in range(nbits):
        out.append(s[6])
        new = [s[6]] + s[0:6]
        new[4] ^= s[6]
        s = new
    return out


def ref_crc_bits(pdu, init):
    s = [(init >> k) & 1 for k in range(24)]                    # position k = bit k of init
    for b in bits_lsb(pdu):
        fb = b ^ s[23]
        new = [fb] + s[0:23]
        for t in (1, 3, 4, 6, 9, 10):
            new[t] ^= fb
        s = new
    return [s[k] for k in range(23, -1, -1)]                    # transmitted from position 23 down


def ref_packet_bits(aa, pdu, ch, init):
    pre = 0x55 if (aa & 1) else 0xAA
    head = [(pre >> i) & 1 for i in range(8)] + [(aa >> i) & 1 for i in range(32)]
    body = bits_lsb(pdu) + ref_crc_bits(pdu, init)
    w = ref_whiten(len(body), ch)
    return head + [a ^ b for a, b in zip(body, w)]


def bits_to_bytes(bits):
    return bytes(sum(bits[8 * j + i] << i for i in range(8)) for j in range(len(bits) // 8))


# ---------------------------------------------------------------- mirror of btle_tx_min.v
def mirror_tx(aa, pdu, ch, init, bit_period=16):
    """Returns the list of (clock, bit, last) the Verilog would emit after tx_start."""
    pre = 0x55 if (aa & 1) else 0xAA
    frame40 = (aa << 8) | pre
    L = len(pdu)
    n_pdu, n_total = 8 * L, 40 + 8 * L + 24
    pdu_int = int.from_bytes(pdu, "little")
    crc = init & 0xFFFFFF
    wh = [(0)] * 7
    wh_init = (ch & 1, (ch >> 1) & 1, (ch >> 2) & 1, (ch >> 3) & 1, (ch >> 4) & 1, (ch >> 5) & 1, 1)
    wh_val = sum(b << (6 - k) for k, b in enumerate(wh_init))        # wh[6]=ch[0] ... wh[0]=1
    out, n, clk = [], 0, 0
    while n < n_total:
        if clk % bit_period == 0:
            if n < 40:
                b = (frame40 >> n) & 1
            elif n < 40 + n_pdu:
                pb = (pdu_int >> (n - 40)) & 1
                wo = (wh_val >> 6) & 1
                b = pb ^ wo
                fb = pb ^ ((crc >> 23) & 1)
                crc = (((crc << 1) & 0xFFFFFF) | fb) ^ (0x00065A if fb else 0)
                wh_val = (((wh_val << 1) & 0x7F) | ((wh_val >> 6) & 1)) ^ (0x10 if (wh_val >> 6) & 1 else 0)
            else:
                m = n - 40 - n_pdu
                cb = (crc >> (23 - m)) & 1
                wo = (wh_val >> 6) & 1
                b = cb ^ wo
                wh_val = (((wh_val << 1) & 0x7F) | ((wh_val >> 6) & 1)) ^ (0x10 if (wh_val >> 6) & 1 else 0)
            out.append((clk, b, n == n_total - 1))
            n += 1
        clk += 1
    return out


# ---------------------------------------------------------------- mirror of msk_modulator.v
ROM = [(4095, 0), (3783, 1567), (2896, 2896), (1567, 3783), (0, 4095), (-1567, 3783),
       (-2896, 2896), (-3783, 1567), (-4095, 0), (-3783, -1567), (-2896, -2896), (-1567, -3783),
       (0, -4095), (1567, -3783), (2896, -2896), (3783, -1567)]


def mirror_msk(bit_events, total_clocks, amp_shift=1, freq_sign=0, pad_mode=1, pad_samples=96,
               phase_init=0):
    """bit_events: dict clock -> (bit, last).  Returns per-clock (i, q), plus pulse clocks."""
    st, ph, sc, ne, dir_, last_r, pc = "IDLE", phase_init, 0, 0, 0, 0, 0
    i_out = q_out = 0
    trace, data_done_at, done_at = [], [], []
    for clk in range(total_clocks):
        trace.append((i_out, q_out))
        bv = clk in bit_events
        bit_in, bit_last = bit_events.get(clk, (0, 0))
        dir_data = bit_in if bv else dir_
        dir_pad = ((1 - dir_) ^ ((pc >> 2) & 1)) if pad_mode else dir_
        dir_ev = dir_pad if st == "PAD" else dir_data
        step_up = dir_ev ^ freq_sign
        ph_n = (ph + 1) % 16 if step_up else (ph - 1) % 16
        ri, rq = ROM[ph_n]
        si, sq = ri >> amp_shift, rq >> amp_shift
        new_sc = (sc + 1) % 4
        if st == "IDLE":
            if bv:
                st, dir_, last_r, ne, new_sc = "DATA", bit_in, bit_last, 1, 0
                ph, i_out, q_out = ph_n, si, sq
        elif st == "DATA":
            if bv:
                dir_, last_r, ne, new_sc = bit_in, bit_last, 1, 0
                ph, i_out, q_out = ph_n, si, sq
            elif sc == 3:
                new_sc = 0
                if ne != 4:
                    ph, i_out, q_out = ph_n, si, sq
                    if ne == 3 and last_r:
                        data_done_at.append(clk)
                        st, pc = "PAD", 0
                    ne += 1
        elif st == "PAD":
            if sc == 3:
                new_sc = 0
                if pc < pad_samples:
                    ph, i_out, q_out = ph_n, si, sq
                    pc += 1
                else:
                    i_out = q_out = 0
                    st = "IDLE"
                    done_at.append(clk)
                    ph = phase_init
        sc = new_sc
    return trace, data_done_at, done_at


# ---------------------------------------------------------------- checks
def main():
    ok_all = True

    # 1. README example, body only: PDU 0100, repo CRC init "123456" (= 0x563412 here), channel 10
    pdu = bytes([0x01, 0x00])
    crc = ref_crc_bits(pdu, 0x563412)
    body = bits_lsb(pdu) + crc
    wh = ref_whiten(len(body), 10)
    crc_bytes = bits_to_bytes(crc).hex()
    wh_bytes = bits_to_bytes([a ^ b for a, b in zip(body, wh)]).hex()
    print("README example: crc", crc_bytes, "(want 9b8950)  whitened", wh_bytes, "(want 9bc14d4c14)")
    ok_all &= (crc_bytes == "9b8950" and wh_bytes == "9bc14d4c14")

    # 2. mirror of btle_tx_min against the reference
    rng = random.Random(3)
    bad = 0
    for _ in range(400):
        L = rng.randrange(2, 40)
        pdu = bytes(rng.randrange(256) for _ in range(L))
        aa, ch, init = rng.getrandbits(32), rng.randrange(40), rng.getrandbits(24)
        ref = ref_packet_bits(aa, pdu, ch, init)
        out = mirror_tx(aa, pdu, ch, init)
        got = [b for _, b, _ in out]
        times_ok = all(c == 16 * k for k, (c, _, _) in enumerate(out))
        last_ok = [l for _, _, l in out] == [False] * (len(out) - 1) + [True]
        if got != ref or not times_ok or not last_ok:
            bad += 1
    print("btle_tx_min mirror vs reference, 400 random packets, mismatches:", bad)
    ok_all &= (bad == 0)

    # 3a. ROM accuracy
    worst = max(max(abs(r[0] - round(4095 * math.cos(math.radians(22.5 * k)))),
                    abs(r[1] - round(4095 * math.sin(math.radians(22.5 * k)))))
                for k, r in enumerate(ROM))
    mag = [math.hypot(*r) for r in ROM]
    print("ROM: worst error vs ideal %d LSB, magnitude %.1f..%.1f" % (worst, min(mag), max(mag)))
    ok_all &= (worst <= 1 and max(mag) < 4096.5 and min(mag) > 4093)

    # 3b. modulator behaviour on a real packet
    pdu = bytes([0x42, 0x0F, 0x01, 0x00, 0x00, 0xEE, 0xFF, 0xC0, 0x02, 0x01, 0x06, 0x05, 0x09,
                 0x42, 0x54, 0x4C, 0x45])
    bits = ref_packet_bits(0x8E89BED6, pdu, 37, 0x555555)
    events = {16 * k + 5: (b, k == len(bits) - 1) for k, b in enumerate(bits)}   # arbitrary start offset
    total = 16 * len(bits) + 5 + 4 * 96 + 40
    for shift, pad_mode in ((1, 1), (0, 0)):
        trace, dd, dn = mirror_msk(events, total, amp_shift=shift, pad_mode=pad_mode)
        last_bit_clk = 16 * (len(bits) - 1) + 5
        print(f"modulator amp_shift={shift} pad_mode={pad_mode}: data_done at clock {dd} "
              f"(expect {last_bit_clk + 12}), done at {dn} (expect {last_bit_clk + 16 + 4 * 96})")
        ok_all &= (dd == [last_bit_clk + 12] and dn == [last_bit_clk + 16 + 4 * 96])
        # samples: change only on 4-clock grid, 4 per bit
        first = 5
        samples = [trace[first + 1 + 4 * k] for k in range(4 * len(bits))]    # value after each event
        # decode with the repo's rule: sample pairs one symbol (4 samples) apart
        amp = 4095 >> shift
        dec_ok = True
        for k in range(len(bits)):
            s0 = samples[4 * k - 1] if k > 0 else (amp, 0)     # sample before this bit's first
            s1 = samples[4 * k + 3]
            cross = s0[0] * s1[1] - s1[0] * s0[1]
            if (cross > 0) != bool(bits[k]):
                dec_ok = False
        print("   repo demodulator rule recovers all %d bits from the samples: %s" % (len(bits), dec_ok))
        ok_all &= dec_ok
        # constant envelope, 22.5 degree steps
        steps = []
        for a, b in zip(samples, samples[1:]):
            c = a[0] * b[1] - b[0] * a[1]
            d = a[0] * b[0] + a[1] * b[1]
            steps.append(math.degrees(math.atan2(c, d)))
        mags = [math.hypot(*s) for s in samples]
        print("   phase step per sample: min %.2f max %.2f deg; envelope spread %.2f%%" % (
            min(steps), max(steps), 100 * (max(mags) - min(mags)) / max(mags)))
        ok_all &= (all(abs(abs(s) - 22.5) < 0.5 for s in steps))
        # zero before and after
        ok_all &= (all(t == (0, 0) for t in trace[:first + 1]) and trace[-1] == (0, 0))

    # 4. testbench with the expected bit stream embedded
    exp = "".join(str(b) for b in bits)
    with open("btle_tx_tb.v", "w") as f:
        f.write(TB_TEMPLATE.replace("@NBITS@", str(len(bits)))
                           .replace("@EXPBITS@", "%d'b%s" % (len(bits), exp)))
    print("wrote btle_tx_tb.v with", len(bits), "expected bits")
    print("ALL CHECKS PASS" if ok_all else "SOME CHECKS FAILED")


TB_TEMPLATE = r'''// btle_tx_tb.v  --  btle_tx_min + msk_modulator, generated by btle_tx_check.py
//
//   iverilog -g2005 -o btle_tx_tb btle_tx_min.v msk_modulator.v btle_tx_tb.v && vvp btle_tx_tb
//
// Default advertising packet (ADV_NONCONN_IND, channel 37, access address 8E89BED6, CRC init
// 555555).  Checks: the whitened bit stream equals the one computed by the independent
// reference encoder, bits are 16 clocks apart, four samples per bit on a 4-clock grid, the
// phase turns the right way for every bit (the repo demodulator's cross-product rule), the
// envelope is constant, data_done and done pulse once each, outputs are zero outside the packet.
//
// NOT RUN when written.

`timescale 1ns/1ps

module btle_tx_tb;
    localparam NBITS = @NBITS@;
    localparam [NBITS-1:0] EXP = @EXPBITS@;     // EXP[NBITS-1] is the first bit on air
    localparam PAD = 96;

    reg clk = 1'b0;
    always #31.25 clk = ~clk;                   // 16 MHz
    reg rst = 1'b1;
    reg tx_start = 1'b0;

    wire bit_out, bit_valid, bit_last, busy;
    wire signed [12:0] i_out, q_out;
    wire data_done, done, active;

    btle_tx_min #(
        .PDU_LEN(17),
        .PDU({376'd0, 8'h45, 8'h4C, 8'h54, 8'h42, 8'h09, 8'h05, 8'h06, 8'h01, 8'h02,
              8'hC0, 8'hFF, 8'hEE, 8'h00, 8'h00, 8'h01, 8'h0F, 8'h42})
    ) u_tx (.clk(clk), .rst(rst), .tx_start(tx_start),
            .bit_out(bit_out), .bit_valid(bit_valid), .bit_last(bit_last), .busy(busy));

    msk_modulator #(.AMP_SHIFT(3'd1), .PAD_MODE(1), .PAD_SAMPLES(PAD)) u_msk (
        .clk(clk), .rst(rst), .bit_in(bit_out), .bit_valid(bit_valid), .bit_last(bit_last),
        .i_out(i_out), .q_out(q_out), .data_done(data_done), .done(done), .active(active));

    integer errors = 0;
    integer nb = 0;                              // bits seen
    integer clkn = 0;
    integer last_bit_clk = -1;
    integer dd_n = 0, dn_n = 0;
    integer sample_changes = 0;
    integer since_change = 0;                    // clocks the output has been unchanged
    integer dot, cross;
    reg     cur_bit = 1'b0;
    reg signed [12:0] pi = 0, pq = 0;

    always @(posedge clk) begin
        clkn <= clkn + 1;

        if (bit_valid) begin
            if (nb < NBITS && bit_out !== EXP[NBITS-1-nb]) begin
                errors = errors + 1;
                $display("FAIL: bit %0d is %b, expected %b", nb, bit_out, EXP[NBITS-1-nb]);
            end
            if (last_bit_clk >= 0 && (clkn - last_bit_clk) != 16) begin
                errors = errors + 1;
                $display("FAIL: bit spacing %0d clocks at bit %0d", clkn - last_bit_clk, nb);
            end
            if ((bit_last === 1'b1) != (nb == NBITS - 1)) begin
                errors = errors + 1;
                $display("FAIL: bit_last wrong at bit %0d", nb);
            end
            last_bit_clk = clkn;
            cur_bit = bit_out;
            nb = nb + 1;
        end
        if (data_done) dd_n = dd_n + 1;
        if (done)      dn_n = dn_n + 1;

        // The output must change on a 4-clock grid.  Every change between two non-zero
        // samples must be a 22.5 degree turn: dot product / (2047 * 2047) is about 0.924.
        if (i_out !== pi || q_out !== pq) begin
            if (sample_changes > 0 && since_change != 3) begin
                errors = errors + 1;
                $display("FAIL: samples %0d clocks apart at %0t", since_change + 1, $time);
            end
            if ((pi != 0 || pq != 0) && (i_out != 0 || q_out != 0)) begin
                dot   = pi * i_out + pq * q_out;
                cross = pi * q_out - i_out * pq;
                if (dot < 3770000 || dot > 3950000) begin
                    errors = errors + 1;
                    $display("FAIL: phase step off, dot=%0d at %0t", dot, $time);
                end
                // while data is being sent the turn direction must follow the current bit
                if (dd_n == 0 && ((cross > 0) != (cur_bit === 1'b1))) begin
                    errors = errors + 1;
                    $display("FAIL: phase turned the wrong way for bit %0d at %0t", nb - 1, $time);
                end
            end
            sample_changes = sample_changes + 1;
            since_change = 0;
        end else begin
            since_change = since_change + 1;
        end
        pi = i_out;
        pq = q_out;
    end

    initial begin
        repeat (6) @(posedge clk);
        rst = 1'b0;
        repeat (10) @(posedge clk);
        tx_start = 1'b1;
        @(posedge clk);
        tx_start = 1'b0;
        // packet: NBITS * 16 clocks, then padding PAD * 4 clocks
        repeat (16 * NBITS + 4 * PAD + 200) @(posedge clk);

        if (nb != NBITS)   begin errors = errors + 1; $display("FAIL: %0d bits, expected %0d", nb, NBITS); end
        if (dd_n != 1)     begin errors = errors + 1; $display("FAIL: data_done pulsed %0d times", dd_n); end
        if (dn_n != 1)     begin errors = errors + 1; $display("FAIL: done pulsed %0d times", dn_n); end
        if (i_out != 0 || q_out != 0) begin errors = errors + 1; $display("FAIL: output not zero afterwards"); end
        if (sample_changes < 4 * NBITS) begin
            errors = errors + 1;
            $display("FAIL: only %0d sample changes, expected at least %0d", sample_changes, 4 * NBITS);
        end

        if (errors == 0) $display("PASS: %0d bits, %0d sample changes", nb, sample_changes);
        else             $display("FAILED: %0d error(s)", errors);
        $finish;
    end
endmodule
'''

if __name__ == "__main__":
    main()
