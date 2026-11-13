// btle_mvp_config.vh  --  every tunable and every unchecked value for btle_mvp_top
//
// Edit values here, or override the matching parameter when instantiating btle_mvp_top.
// Each entry says:
//   STATUS  VERIFIED  = checked against the AT86RF215 datasheet (Atmel-42415E, 05/2016)
//           DERIVED   = follows from verified facts plus a design choice
//           ESTIMATE  = a sensible number I could not check; expect to tune it
//           ASSUMED   = depends on something I have not seen (your board, the repo source)
//   WHAT    what the value does
//   CHANGE  when and why you would need to change it
//
// Bring-up order that usually finds problems fastest:
//   1. section 1 (does the local clock match?), then section 3 (does the radio configure?)
//   2. section 4 (does the LVDS link lock?)  -> led_ready on, led_fault off
//   3. section 5 (does a phone or sniffer decode the transmitted packet?)
//   4. section 6 (does a received packet print on the UART?)
//
// NOT SIMULATED OR SYNTHESISED when written.

`ifndef BTLE_MVP_CONFIG_VH
`define BTLE_MVP_CONFIG_VH

// =====================================================================================
// 1. Local clock and sequencer timing
// =====================================================================================

// CFG_CLK_LOCAL_HZ
//   STATUS  DERIVED.  On the pico-ice family the RP microcontroller generates the FPGA clock in
//           software: the pico-ice SDK documents ice_fpga_init_clock() with 48, 24, 16, 12, 8, 6,
//           4, 3, 2 or 1 MHz, and the MicroPython example uses 48.  I have not seen the pico2-ice
//           SDK itself, and which FPGA pin receives the clock is ASSUMED (pin 35, a global-clock
//           pin, as on the original pico-ice).
//   WHAT    Frequency of clk_local, the pin that clocks the radio sequencer, SPI and UART.
//           This is NOT the radio clock (RXCLK, 64 MHz).  Every time below is converted to
//           clock cycles from this number.
//   CHANGE  It must equal whatever the RP2350 firmware sets.  12 MHz is a good choice (SPI and
//           UART dividers divide evenly).  If it is wrong, every delay, the SPI speed and the
//           UART baud rate are wrong by the same factor.  Must be at least 1 MHz.  On a board
//           without a microcontroller, use whatever oscillator you have.
`define CFG_CLK_LOCAL_HZ 12000000

// CFG_SPI_HZ
//   STATUS  VERIFIED limit: the radio allows up to 25 MHz (datasheet 10.12).  The value is a choice.
//   WHAT    Target SPI clock.  Rounded to CLK_LOCAL_HZ / (2 * n).  Cannot exceed CLK/2.
//   CHANGE  Lower it if the SPI wires between the FPGA and the XPRO are long or the radio
//           reads back garbage (part number check fails: led_fault blinking).  Raising it
//           shortens the TXPREP command, so you could shorten CFG_MSK_PAD_US.
`define CFG_SPI_HZ 2000000

// CFG_RST_LOW_US
//   STATUS  VERIFIED: RSTN must be low at least 625 ns (tRST, datasheet 10.4).
//   WHAT    How long RSTN is held low.
//   CHANGE  Rarely.  Lengthen it if the XPRO's reset button circuit adds capacitance.
`define CFG_RST_LOW_US 100

// CFG_BOOT_US
//   STATUS  VERIFIED: the radio reaches TRXOFF within 1 us of RSTN release (tRESET_TRXOFF).
//   WHAT    Wait after releasing RSTN before the first SPI access.  The sequencer also polls
//           the state register, so this is only a head start.
//   CHANGE  Rarely.
`define CFG_BOOT_US 100

// CFG_POLL_MAX
//   STATUS  DERIVED.
//   WHAT    How many times a state poll (e.g. wait for TXPREP) is retried before declaring a fault.
//           TRXOFF -> TXPREP takes up to 200 us (tTRXOFF_TXPREP), about 25 polls at 2 MHz SPI.
//   CHANGE  Raise it if you slow the SPI clock a lot; lower it to detect a dead radio sooner.
`define CFG_POLL_MAX 4096

// CFG_POLL_GAP_US
//   STATUS  DERIVED.
//   WHAT    Pause between polls.
//   CHANGE  Rarely.
`define CFG_POLL_GAP_US 2

// CFG_TX_PERIOD_MS
//   STATUS  A choice.
//   WHAT    Time between transmitted packets.  The radio listens in between.
//   CHANGE  Lower for more transmissions per second (a phone scanning for you sees you sooner),
//           higher to spend more time receiving.  BLE advertising intervals are 20 ms to 10 s.
`define CFG_TX_PERIOD_MS 100

// CFG_TX_TIMEOUT_MS
//   STATUS  DERIVED: a 200-bit packet takes 200 us, so 10 ms is very generous.
//   WHAT    How long the sequencer waits for the transmit datapath before declaring a fault.
//   CHANGE  Raise it only if you make the packet much longer.
`define CFG_TX_TIMEOUT_MS 10

// CFG_SYNC_US
//   STATUS  ESTIMATE.  The datasheet gives the link start-up time (1 us for the radio's
//           receiver) and requires 32 zero bits before the first word, which is far less
//           than this.  The margin is deliberate.
//   WHAT    After entering TXPREP the sequencer starts sending zero-amplitude I/Q words and
//           waits this long before telling the radio to transmit, so the radio's I/Q receiver
//           has synchronised.
//   CHANGE  If transmissions are corrupted at the start or not seen at all, raise it.  Check
//           CFG_EN_SYNC_POLL in section 3 to read the radio's own sync flag instead.
`define CFG_SYNC_US 50

// CFG_LEAD_US
//   STATUS  ESTIMATE.  Datasheet 6.1.4 and Table 10-7: the PA ramp starts 4 us after the TX
//           command and lasts the TXCUTC.PARAMP time (4 us at reset).  Data is delayed by
//           the radio's processing delay (4 us at the settings used).
//   WHAT    Time from "radio is in TX" to the first packet bit, so the PA has finished ramping.
//   CHANGE  Raise it if you increase PARAMP (section 3).  If the start of the preamble is
//           attenuated, raise it; there is no harm in a larger value except a longer burst.
`define CFG_LEAD_US 20

// CFG_FAULT_RETRY_MS
//   STATUS  A choice.
//   WHAT    After a fault (led_fault on) the sequencer waits this long, resets the radio and tries again.
//   CHANGE  Lower it for faster recovery while debugging.
`define CFG_FAULT_RETRY_MS 100


// =====================================================================================
// 2. Packet, channel and addresses
// =====================================================================================

// CFG_BLE_CHANNEL
//   STATUS  VERIFIED formula: f = (CCF0 + CN*CS)*25 kHz + 1.5 GHz (datasheet 6.3.2), and the
//           BLE channel to frequency map is from the Bluetooth spec.
//   WHAT    BLE channel index, 0 to 39.  37 = 2402 MHz, 38 = 2426 MHz, 39 = 2480 MHz are the
//           advertising channels.  The same number seeds the whitening LFSR in the transmitter
//           and the descrambler in the receiver, and sets the radio frequency.
//   CHANGE  Use 38 or 39 to advertise elsewhere.  Channel 37 is only 2 MHz from the lower
//           edge of the 2.4 GHz band, so band-edge limits matter most there.
//   LIMIT   Do not use channel 0.  The repo's scramble_core.v treats channel number 0 as "not
//           set" and substitutes all ones (channel 63), so the receiver would descramble wrongly
//           (VERIFIED in scramble_core.v).  The transmitter here uses the number as given.
`define CFG_BLE_CHANNEL 37

// CFG_ACCESS_ADDRESS
//   STATUS  VERIFIED: advertising channels always use 0x8E89BED6 (Bluetooth spec).
//   WHAT    32-bit access address used for both transmit and receive.  The preamble is chosen
//           automatically (0xAA if the address LSB is 0, else 0x55).
//   CHANGE  Only for data channels or non-standard experiments.
`define CFG_ACCESS_ADDRESS 32'h8E89BED6

// CFG_CRC_INIT
//   STATUS  VERIFIED.  The convention was fitted to the repo's README example, and crc24_core.v
//           (now seen) confirms it: it swaps the first and last seed byte on load, and a zero
//           seed becomes 0x555555.  Its update taps match btle_tx_min's.
//   WHAT    24-bit CRC LFSR start value, position k = bit k.  The repo's descriptor form is the
//           byte-swapped number: repo "123456" is 24'h563412 here.  The receiver (btle_rx) is
//           given the byte-swapped form automatically, so both directions use this one value.
//           0x555555 is the same either way.
//   CHANGE  Only for data channels.
`define CFG_CRC_INIT 24'h555555

// CFG_TX_PDU_LEN and CFG_TX_PDU
//   STATUS  A choice.  The default is a non-connectable advertisement from random address
//           C0:FF:EE:00:00:01 with flags and the name "BTLE".
//   WHAT    The transmitted packet's PDU: 2-byte header then payload, at most 64 bytes in this
//           file (39 for legacy BLE).  CFG_TX_PDU lists the bytes LAST FIRST: the rightmost
//           entry is byte 0, the first byte on air.  Byte 1 is the payload length and must equal
//           CFG_TX_PDU_LEN - 2.  CRC is added in hardware.
//   CHANGE  Edit to change what a phone sees.  Keep the length byte consistent or receivers
//           will reject the packet.
`define CFG_TX_PDU_LEN 17
`define CFG_TX_PDU { 8'h45, 8'h4C, 8'h54, 8'h42, 8'h09, 8'h05, 8'h06, 8'h01, 8'h02, \
                     8'hC0, 8'hFF, 8'hEE, 8'h00, 8'h00, 8'h01, 8'h0F, 8'h42 }


// =====================================================================================
// 3. Radio registers (AT86RF215), written over SPI by rf215_init
// =====================================================================================

// CFG_IQIFC0_VAL   (register RF_IQIFC0, 0x000A, reset 0x14)
//   STATUS  VERIFIED field layout (datasheet 4.5.8.1).  The DRV choice is DERIVED.
//   WHAT    0x36 = CMV1V2 set (1.2 V common mode, the IEEE 1596 LVDS level your SN65LVDS049
//           expects), DRV = 3 (4 mA drive), CMV unchanged, EEC = 0 (TX start and stop by SPI).
//           Numbers behind it (both data sheets): the radio's IEEE-mode driver gives |Vod| of
//           200 mV typical at 2 mA (Table 10-31) and Vod scales with the DRV current (DRV 0..3 =
//           1..4 mA, so about 400 mV at 4 mA).  The SN65LVDS049 receiver switches at +/-100 mV
//           (Table 6.5) and accepts 0.05 to 2.35 V common mode, so 2 mA leaves only about 2x
//           margin on a typical part and 4 mA about 4x.  On the TX side the SN65LVDS049 driver
//           gives 250..450 mV differential at 1.125..1.375 V offset, so each line stays between
//           0.9 V and 1.6 V; the radio's IEEE-mode receiver accepts 0.825..1.575 V per line
//           (Table 10-33), so the single worst corner exceeds it by 25 mV and typical parts do not.
//   CHANGE  Use DRV = 1 (0x16) if you want the exact 2 mA the radio's tables are written for
//           and a quick check shows the link locks.  Use DRV = 2 (0x26) to compromise.  Do not
//           set bit 0 (EEC) unless you also add embedded TX control to lvds_tx.
`define CFG_IQIFC0_VAL 8'h36

// CFG_SKEWDRV   (IQIFC1 bits 1:0, reset 2)
//   STATUS  VERIFIED values: 0..3 = 1.906, 2.906, 3.906, 4.906 ns clock-to-data delay on the
//           radio's data output (Table 4-18).  2 is centre alignment.  Whether 2 is best on
//           YOUR board is ASSUMED.
//   WHAT    Moves the radio's receive data relative to RXCLK.  The FPGA's clock tree delays the
//           clock that samples the data by a few nanoseconds.
//   CHANGE  If lvds_rx locks only intermittently or the received I/Q is noisy, try 3, then 1.
//           Also see CFG_LVDS_RX_SWAP_PAIR.  Can only be changed while the radio is in TRXOFF,
//           which is when the sequencer writes it.
`define CFG_SKEWDRV 2

// CFG_RXDFE_VAL   (RF24_RXDFE, 0x020A)
//   STATUS  VERIFIED field layout and tables (6.2.5.2).  The RCUT choice is DERIVED.
//   WHAT    0x61 = RCUT 3 (cutoff 0.75 * fs/2 = 1.5 MHz) and SR 1 (fs = 4 Msps).  Reset is 0x01
//           (RCUT 0, a 0.5 MHz cutoff, too narrow for 1 Msym/s GFSK).
//   CHANGE  Use 0x81 (RCUT 4, widest) if receive sensitivity is poor; use 0x41 (RCUT 2,
//           1 MHz) to cut noise if packets are strong.  Keep SR = 1: the whole design assumes 4 Msps.
`define CFG_RXDFE_VAL 8'h61

// CFG_TXDFE_VAL   (RF24_TXDFE, 0x0213)
//   STATUS  VERIFIED field layout and tables (6.1.5.2).  The RCUT choice is DERIVED.
//   WHAT    0x81 = RCUT 4 (TX pre-filter bypassed, lowest delay, 2 us) and SR 1 (4 Msps).
//   CHANGE  Use 0x61 (RCUT 3, 1.5 MHz) to add a little extra filtering of the MSK sidelobes.
//           That changes the processing delay from 2 us to 4 us (Table 6-1); the lead and
//           padding times have margin for it.  Keep SR = 1.
`define CFG_TXDFE_VAL 8'h81

// CFG_EN_RXBWC / CFG_RXBWC_VAL   (RF24_RXBWC, 0x0209)
//   STATUS  VERIFIED reset value 0x0B = 2000 kHz channel bandwidth (Table 6-14).
//   WHAT    Receiver analog channel filter.  Disabled by default so the radio keeps its reset value.
//   CHANGE  Enable and set 0x09 (1250 kHz) or 0x08 (1000 kHz) to reject more adjacent-channel
//           noise.  A narrower filter loses signal if the other device's frequency is off.
`define CFG_EN_RXBWC 0
`define CFG_RXBWC_VAL 8'h0B

// CFG_EN_TXCUTC / CFG_TXCUTC_VAL   (RF24_TXCUTC, 0x0212)
//   STATUS  VERIFIED reset value 0x08 = LPFCUT 500 kHz, PARAMP 4 us (Tables 6-3, 6-4).  The
//           radio's analog filter is second order (6.1.2).  The study in ble_gfsk_study.py
//           (a Butterworth stand-in, so APPROXIMATE) shows the reset 500 kHz setting gives
//           MSK adjacent-channel power of about -53 dBc, close to a Gaussian filter, with
//           frequency deviation inside the BLE limits.  1 MHz gave only about -41 dBc.
//   WHAT    TX low-pass cutoff (bits 3:0, 0x8 = 500 kHz, 0xB = 1000 kHz maximum) and PA ramp time
//           (bits 7:6: 0 = 4 us, 1 = 8, 2 = 16, 3 = 32).  Disabled by default.
//   CHANGE  Enable with a longer PARAMP (0x48 = 8 us, 0x88 = 16 us) to reduce splatter at
//           the start and end of the burst.  If you do, raise CFG_LEAD_US and CFG_MSK_PAD_US
//           to match.  Raise the cutoff (low nibble) only if a receiver cannot decode the
//           heavily filtered signal.
`define CFG_EN_TXCUTC 0
`define CFG_TXCUTC_VAL 8'h08

// CFG_EN_PAC / CFG_PAC_VAL   (RF24_PAC, 0x0214, reset 0x7F = maximum power)
//   STATUS  VERIFIED layout: PACUR bits 6:5, TXPWR bits 4:0, about 1 dB per step (6.1.5.3), and
//           that the maximum is up to +14 dBm.  The dBm of any setting below max is an
//           ESTIMATE (31 - 14 = 17 is about 0 dBm).  The exact curve is Figure 11-3 in the datasheet.
//   WHAT    Transmit power.  0x71 = TXPWR 17, roughly 0 dBm.
//   CHANGE  Lower it (0x6C and below) if the receiver you test with is within a metre or two
//           and distorts, or to stay within a lab limit.  Raise it (0x7F) for range.  Read the
//           chart to pick a real dBm figure.  This also depends on the SMA2 antenna and cable.
`define CFG_EN_PAC 1
`define CFG_PAC_VAL 8'h71

// CFG_EN_SYNC_POLL / CFG_SYNC_MASK   (RF_IQIFC2.SYNC, bit 7)
//   STATUS  VERIFIED: bit 7 is set when the radio's I/Q receiver has received a data word and is
//           cleared by each read (4.5.6, 4.5.8.3).
//   WHAT    When enabled, the sequencer reads IQIFC2 after it has started the I/Q stream and
//           refuses to command TX until the bit is set.  Disabled by default so a wiring
//           fault shows up as a missing packet rather than a fault loop.
//   CHANGE  Enable it once the transmit path works, to turn a silent failure into led_fault.
//           It is the best on-chip check that the TX LVDS pair is wired and driven correctly.
`define CFG_EN_SYNC_POLL 0
`define CFG_SYNC_MASK 8'h80


// =====================================================================================
// 4. LVDS link (lvds_rx / lvds_tx), FPGA side of the I/Q interface
// =====================================================================================

// CFG_LVDS_RX_LOCK_WORDS
//   STATUS  DERIVED from the Python model: 3 consecutive matching words gave no false locks in 3000 trials.
//   WHAT    Number of consecutive correct sync patterns, 16 clocks apart, needed to lock.
//   CHANGE  Raise (4 or 5) if lock is falsely declared on a noisy line; lower to 2 to lock a word sooner.
`define CFG_LVDS_RX_LOCK_WORDS 3

// CFG_LVDS_RX_MISS_MAX
//   STATUS  DERIVED.
//   WHAT    Consecutive bad words before lock is dropped.
//   CHANGE  Raise if single bit errors on the link make lock drop and reacquire.
`define CFG_LVDS_RX_MISS_MAX 2

// CFG_LVDS_RX_CHECK_LSB
//   STATUS  VERIFIED: in receive data I_DATA[0] and Q_DATA[0] are always 0 (4.5.4).
//   WHAT    Also require those two bits to be 0 when looking for the word boundary.
//   CHANGE  Set 0 only if you find a radio revision that sets them.
`define CFG_LVDS_RX_CHECK_LSB 1

// CFG_LVDS_RX_INVERT / CFG_LVDS_TX_INVERT
//   STATUS  ASSUMED: the polarity of the P and N wires through your SATA cables and the adapter.
//           The adapter pin mapping itself was checked against the SN65LVDS049 pin table and matches
//           (RIN1 = RXCLK, RIN2 = RXD24, DOUT1 = TXCLK, DOUT2 = TXD, EN high and EN-bar low).
//           The XPRO user guide gives RXDP24 on J101 pin 2 and RXDN24 on pin 3.
//   WHAT    1 inverts the data line (a swapped differential pair).  The clock is not inverted.
//   CHANGE  If lvds_rx never locks but the line is toggling, try INVERT = 1.  For TX, set it
//           if the radio's IQIFC2.SYNC never sets (enable CFG_EN_SYNC_POLL to see this).
`define CFG_LVDS_RX_INVERT 0
`define CFG_LVDS_TX_INVERT 0

// CFG_LVDS_RX_SWAP_PAIR
//   STATUS  VERIFIED intent (bit 31 on the rising edge, Figure 4-10), but the actual phase
//           through the SN65LVDS049 and the FPGA's input cells is ASSUMED.
//   WHAT    1 swaps which edge's sample is treated as the first bit of each pair.
//   CHANGE  If the line is clean and correct but never locks, and INVERT did not help, try 1.
`define CFG_LVDS_RX_SWAP_PAIR 0

// CFG_LVDS_TX_MIN_IDLE_WORDS
//   STATUS  VERIFIED: at least 2.5 us (10 words) of zeros between transmit bursts (4.5.6).
//   WHAT    Zero words sent before the first data word of a burst.
//   CHANGE  Do not lower it below 1 (32 zero bits are needed for initial sync) or below 10 for
//           back-to-back bursts.
`define CFG_LVDS_TX_MIN_IDLE_WORDS 10


// =====================================================================================
// 5. MSK modulator (transmit waveform)
// =====================================================================================

// CFG_MSK_AMP_SHIFT
//   STATUS  ESTIMATE.
//   WHAT    Sample amplitude is 4095 >> this.  1 = 2047, half of full scale.
//   CHANGE  Use 2 or 3 if the output spectrum shows clipping spurs; use 0 for the most output
//           for a given PAC setting, accepting less headroom in the radio's filters.
`define CFG_MSK_AMP_SHIFT 1

// CFG_MSK_FREQ_SIGN
//   STATUS  Sense of rotation VERIFIED to agree with the repo: gfsk_demodulation.v decides 1 when
//           i0*q1 - i1*q0 > 0, i.e. counter-clockwise rotation, the same sense this modulator
//           makes with FREQ_SIGN = 0.  What is ASSUMED is only whether the radio's I/Q interface
//           preserves the spectrum's orientation.
//   WHAT    0: a 1 bit is a positive frequency deviation (BLE convention).  1: mirrored.
//   CHANGE  If a phone or sniffer sees energy on the right channel but never decodes a
//           packet, set to 1 and retest.  The same issue on receive is CFG_RX_NEGATE_Q.
`define CFG_MSK_FREQ_SIGN 0

// CFG_MSK_PAD_MODE
//   STATUS  A choice.
//   WHAT    Signal sent after the last bit while the PA ramps down.  0 = hold the last
//           frequency; 1 = alternate runs of opposite frequency (no net offset).
//   CHANGE  Use 0 if you want the simplest possible waveform.
`define CFG_MSK_PAD_MODE 1

// CFG_MSK_PAD_US
//   STATUS  ESTIMATE.  Must cover: SPI time for the TXPREP command (about 12 us at 2 MHz SPI),
//           the PA ramp (PARAMP, 4 us at reset) and processing delay (2 to 4 us).
//   WHAT    How long the modulator keeps sending a non-zero signal after the last bit.
//   CHANGE  Raise it when you slow the SPI clock or lengthen PARAMP (about SPI time + PARAMP + 10 us).
//           If the end of the packet shows a sudden drop in the spectrum, raise it.
`define CFG_MSK_PAD_US 24

// CFG_MSK_PHASE_INIT
//   STATUS  A choice.
//   WHAT    Starting phase in 22.5 degree steps.
//   CHANGE  Almost never.
`define CFG_MSK_PHASE_INIT 4'd0


// =====================================================================================
// 6. Receive chain and debug output
// =====================================================================================

// CFG_RX_SET_SPS and CFG_RX_SAMPLE_PER_SYMBOL
//   STATUS  VERIFIED against the uploaded btle_rx.v: the parameter exists (default 8).  BUT the
//           original does not work below 8: its phase counter wraps at 8 and several array
//           accesses are written out for exactly 8 phases.  btle_rx_sps.v (and btle_rx_sps.patch,
//           a 4-part diff) fixes that and is unchanged at 8.  COMPILE btle_rx_sps.v INSTEAD OF btle_rx.v.
//   WHAT    Tells btle_rx how many samples per symbol it gets.  At 4 Msps it must be 4 (the repo
//           design was 8 at 8 Msps).  Fewer phases also halves the receiver area.
//   CHANGE  Leave at 4.  Do not raise it above 4 without also raising the radio's sample rate;
//           the radio's I/Q interface cannot go above 4 Msps.
`define CFG_RX_SET_SPS
`define CFG_RX_SAMPLE_PER_SYMBOL 4

// CFG_RX_IQ_BITS
//   STATUS  DERIVED from reading gfsk_demodulation.v: the detector only uses the SIGN of
//           i0*q1 - i1*q0, and it works in 2x this width, so the width of the I/Q input sets the
//           multiplier size.  The repo default is 16; the radio only produces 13 bits.
//   WHAT    Width of the I/Q samples handed to btle_rx (13 to 16).  At 13 the demodulator's
//           multipliers are 13x13 instead of 16x16 (the sign extension is synthesised away), which
//           matters because the iCE40UP5K has only 8 DSP blocks and this design has 4 cores x 2
//           multipliers.  No overflow is possible at 13 bits.
//   CHANGE  Leave at 13.  Use 16 only to mimic the original design exactly.  To save area further,
//           the earlier simulation showed little loss down to 6 bits, but that needs scaling by
//           the radio's AGC level and is not provided here.
`define CFG_RX_IQ_BITS 13

// CFG_RX_NEGATE_Q
//   STATUS  ASSUMED, same reason as CFG_MSK_FREQ_SIGN.
//   WHAT    1 negates Q before the demodulator, mirroring the spectrum.
//   CHANGE  If lvds_rx locks (rx_lock) and the signal looks fine but no packets decode, set 1 and
//           retest with a known transmitter.  The radio also has RXBWC.IFI (IF inversion) for the
//           analog side; the datasheet says to leave it alone for normal operation.
`define CFG_RX_NEGATE_Q 0

// CFG_RX_RAM_READ_WAIT
//   STATUS  DERIVED.  sdpram_one_clk.v (seen) has a registered read, one clock.  sdpram_two_clk.v
//           was not uploaded; it was described earlier as the same template with the read on
//           clkb.  btle_rx adds a combinational mux on best_phase (seen).  4 clocks is generous.
//   WHAT    Clock cycles the UART dump waits after setting the RAM address.
//   CHANGE  Raise it (8, 16) if printed bytes look shifted, repeated or stale.
`define CFG_RX_RAM_READ_WAIT 4

// CFG_RX_DUMP_BAD_CRC
//   STATUS  A choice.
//   WHAT    1 also prints packets whose CRC failed, prefixed "BAD:".
//   CHANGE  Useful for debugging a marginal link; the contents of a bad packet are unreliable.
`define CFG_RX_DUMP_BAD_CRC 0

// CFG_UART_BAUD
//   STATUS  A choice.
//   WHAT    Baud rate of the packet dump on uart_txd (8N1).
//   CHANGE  Match your serial terminal.  Must be well below CFG_CLK_LOCAL_HZ (at least 16 times lower is comfortable).
`define CFG_UART_BAUD 115200

// CFG_LED_STRETCH_MS
//   STATUS  A choice.
//   WHAT    How long short events (a packet sent, a packet received) light their LED.
//   CHANGE  Whatever is easy to see.
`define CFG_LED_STRETCH_MS 100

`endif
