#!/usr/bin/env python3
"""
Cycle-level Python mirror of the framing logic in lvds_tx.v / lvds_rx.v.

It checks the algorithm, not the Verilog: word packing, DDR pair order, the
sync search and lock logic, and recovery of I/Q.  If you change a slice or a
constant in the HDL, change it here and rerun.

Word format (AT86RF215 datasheet 4.5.4):
  [31:30] I_SYNC=0b10  [29:16] I_DATA[13:0]  [15:14] Q_SYNC=0b01  [13:0] Q_DATA[13:0]
  samples are I_DATA[13:1] / Q_DATA[13:1], 13-bit two's complement; bit 0 is control/unused.
DDR order (datasheet 4.5.3, Figure 4-10): bit 31 is on the rising edge, bit 30 on the
falling edge, so each clock cycle carries the pair {odd bit, even bit}.
"""
import random

LOCK_WORDS = 3     # consecutive matching words needed to lock
CHECK_LSB = True   # also require I_DATA[0] = Q_DATA[0] = 0, which the radio guarantees on RX (4.5.4)
MISS_MAX = 2       # consecutive misses before lock is dropped


def build_word(i, q, ctrl=0):
    iu, qu = i & 0x1FFF, q & 0x1FFF
    return (0b10 << 30) | (iu << 17) | (ctrl << 16) | (0b01 << 14) | (qu << 1)


def word_pairs(w):
    # one pair per clock cycle, {rise, fall} = {bit 31, bit 30}, {bit 29, bit 28}, ...
    return [((w >> (31 - 2 * k)) & 1, (w >> (30 - 2 * k)) & 1) for k in range(16)]


def sext13(v):
    return v - 0x2000 if v & 0x1000 else v


class RxFramer:
    def __init__(self):
        self.sr = 0
        self.cand = False
        self.cyc = 0
        self.ok = 0
        self.miss = 0
        self.locked = False

    def clock(self, pair):
        """One RXCLK cycle.  Returns (i, q) when a valid word completes, else None."""
        self.sr = ((self.sr << 2) | (pair[0] << 1) | pair[1]) & 0xFFFFFFFF
        match = ((self.sr >> 30) & 3) == 0b10 and ((self.sr >> 14) & 3) == 0b01
        if CHECK_LSB:
            match = match and ((self.sr >> 16) & 1) == 0 and (self.sr & 1) == 0
        out = None
        if not self.cand:
            if match:
                self.cand, self.cyc, self.ok, self.miss = True, 0, 1, 0
        else:
            at_boundary = (self.cyc == 15)
            self.cyc = (self.cyc + 1) & 15
            if at_boundary:
                if match:
                    self.miss = 0
                    if not self.locked:
                        self.ok += 1
                        if self.ok >= LOCK_WORDS:
                            self.locked = True
                    if self.locked:
                        out = (sext13((self.sr >> 17) & 0x1FFF), sext13((self.sr >> 1) & 0x1FFF))
                else:
                    self.miss += 1
                    if (not self.locked) or self.miss >= MISS_MAX:
                        self.cand, self.locked, self.ok = False, False, 0
        return out


def run(n_words, prefix_len, rng):
    sent = [(rng.randrange(-4096, 4096), rng.randrange(-4096, 4096)) for _ in range(n_words)]
    pairs = [(rng.getrandbits(1), rng.getrandbits(1)) for _ in range(prefix_len)]
    for i, q in sent:
        pairs += word_pairs(build_word(i, q))
    fr, got = RxFramer(), []
    for p in pairs:
        r = fr.clock(p)
        if r is not None:
            got.append(r)
    return sent, got


class TxSerializer:
    """Mirror of lvds_tx.v's serialiser and of the iCE40 DDR output primitive.

    iCE40 SB_IO PIN_TYPE 6'b010000: D_OUT_0 is captured at the rising edge and shown during the
    high phase; D_OUT_1 is captured at the FALLING edge and shown during the low phase
    (Lattice TN1253 and the iCE40 data sheet).  Logic registers update at the rising edge, so at
    the falling edge the primitive sees the value assigned at that same rising edge, while at the
    rising edge it sees the value assigned one edge earlier.  The odd bits therefore have to be
    presented one clock cycle ahead of the even bits:
        at edge k:  d_fall <= B_k = bit[30-2k]      d_rise <= A_(k+1) = bit[29-2k]
    """
    def __init__(self):
        self.wc = 0
        self.sh = 0
        self.d_rise = 0
        self.d_fall = 0

    def edge(self, next_word):
        """One rising edge.  Returns (high-phase pin, low-phase pin) for the cycle that starts here."""
        hi = self.d_rise                       # primitive samples D_OUT_0 at this edge
        last = (self.wc == 15)
        if last:
            nw = next_word()
            new_rise = (nw >> 31) & 1
            new_sh = (nw << 1) & 0xFFFFFFFF
        else:
            new_rise = (self.sh >> 30) & 1
            new_sh = (self.sh << 2) & 0xFFFFFFFF
        self.d_fall = (self.sh >> 31) & 1
        self.d_rise, self.sh = new_rise, new_sh
        self.wc = (self.wc + 1) & 15
        lo = self.d_fall                       # primitive samples D_OUT_1 at the falling edge
        return hi, lo


def tx_to_rx_check(rng, n_words=80):
    """TX serialiser -> ideal DDR channel -> RX framer, from a cold start."""
    ser, fr = TxSerializer(), RxFramer()
    sent = [(rng.randrange(-4096, 4096), rng.randrange(-4096, 4096)) for _ in range(n_words)]
    queue = [(0, 0)] * 12 + sent                 # zero words first, as the stream starts after idle
    zero_words = 12
    it = iter(queue)
    nxt = {"n": 0}

    def next_word():
        item = next(it, None)
        nxt["n"] += 1
        if item is None or nxt["n"] <= zero_words:
            return 0                              # idle: a zero word (32 zero bits)
        return build_word(*item)

    got = []
    for _ in range(16 * (len(queue) + 4)):
        r = fr.clock(ser.edge(next_word))
        if r is not None:
            got.append(r)
    lost = len(sent) - len(got)
    return lost >= 0 and got == sent[lost:], lost


def main():
    rng = random.Random(7)
    bad = 0
    lost_hist = {}
    for trial in range(3000):
        sent, got = run(60, rng.randrange(0, 200), rng)
        # the recovered words must be an exact tail of what was sent
        lost = len(sent) - len(got)
        ok = lost >= 0 and got == sent[lost:]
        lost_hist[lost] = lost_hist.get(lost, 0) + 1
        if not ok:
            bad += 1
    print("random-prefix trials: 3000, mismatches:", bad)
    print("words lost before lock (count of trials):", dict(sorted(lost_hist.items())))

    # extremes: full-scale samples survive the bit mapping
    fr = RxFramer()
    seq = [(-4096, 4095), (4095, -4096), (0, 0), (-1, 1), (1, -1)] * 4
    pairs = []
    for i, q in seq:
        pairs += word_pairs(build_word(i, q))
    got = [r for p in pairs for r in [fr.clock(p)] if r is not None]
    print("full-scale words recovered:", len(got), "of", len(seq),
          "exact tail:", got == seq[len(seq) - len(got):])

    # radio stops sending words (receiver sees a constant line): lock must drop
    fr = RxFramer()
    pairs = []
    for i, q in seq:
        pairs += word_pairs(build_word(i, q))
    for p in pairs:
        fr.clock(p)
    locked_before = fr.locked
    for _ in range(200):
        fr.clock((1, 1))       # fail-safe receiver output idles high
    print("lock dropped after line goes idle:", locked_before and not fr.locked)

    # TX serialiser -> RX framer, cold start, DDR timing as the iCE40 primitive implements it
    bad_tx, lost_tx = 0, []
    for _ in range(200):
        ok, lost = tx_to_rx_check(rng)
        bad_tx += (not ok)
        lost_tx.append(lost)
    print("tx->rx loopback: 200 runs, failures:", bad_tx,
          "words lost before lock, min/max:", min(lost_tx), max(lost_tx))

    # all-zero idle line never locks
    fr = RxFramer()
    for _ in range(500):
        fr.clock((0, 0))
    print("idle zeros never lock:", not fr.locked)


if __name__ == "__main__":
    main()
