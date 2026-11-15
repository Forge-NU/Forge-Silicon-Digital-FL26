// btle_mvp_top.v  --  BLE MVP top level: AT86RF215 I/Q radio on an FPGA, no microcontroller
//
//   clk_local --> rf215_init (SPI, state sequencer) ------> radio SPI + RSTN
//                     |  stream_en, tx_go / tx_data_done, tx_done
//                     v
//   rxclk_in --> bb_clkgen (bb_clk = rxclk/4, slot)
//        TX: btle_tx_min -> msk_modulator -> lvds_tx -> txd_out / txclk_out
//        RX: rxd_in -> lvds_rx -> btle_rx -> pdu_uart_dump -> uart_txd
//
// Clock domains (the radio is the I/Q clock master: RXCLK runs only in TXPREP, TX and RX):
//   clk_local : sequencer, SPI, UART, LEDs.  Exists always.
//   rxclk_in  : 64 MHz DDR clock from the radio.  lvds_rx, lvds_tx, bb_clkgen.
//   bb_clk    : rxclk / 4 = 16 MHz.  btle_tx_min, msk_modulator, btle_rx.
// Crossings: single events use pulse2tog -> tog2pulse; stream_en is synchronised inside
// lvds_tx; I/Q between rxclk and bb_clk uses the `slot` rule described in bb_clkgen.v.
//
// All tunable and unchecked values come from btle_mvp_config.vh, each overridable here.
//
// FILES (compile order is not important in most tools; the include path must reach the .vh):
//   mine : btle_mvp_top.v btle_mvp_config.vh rf215_init.v spi_master.v bb_clkgen.v ddr_io.v
//          lvds_rx.v lvds_tx.v btle_tx_min.v msk_modulator.v pdu_uart_dump.v sync_cells.v
//          btle_rx_sps.v (a patched copy of the repo's btle_rx.v; see below)
//   repo : btle_rx_core.v gfsk_demodulation.v search_unique_bit_sequence.v scramble_core.v
//          crc24_core.v serial_in_ram_out.v sdpram_two_clk.v   (the compile line in btle_rx.v)
//          NOT used: btle_rx.v itself, btle_tx, gauss_filter, vco, bit_repeat_upsample, crc24,
//          scramble, btle_phy, btle_ll, auxiliary_daemon, clock_domain_conversion_iq.
//
// btle_rx.v, btle_rx_core.v and serial_in_ram_out.v were checked: the ports and parameters
// used below match them exactly.  btle_rx_sps.v is needed because the original btle_rx only
// works with SAMPLE_PER_SYMBOL = 8 and this design runs 4 phases; see btle_rx_sps.patch.
// gfsk_demodulation.v, crc24_core.v, scramble_core.v, search_unique_bit_sequence.v and
// sdpram_one_clk.v were checked as well.  Only sdpram_two_clk.v has not been seen.  Set the
// ICE40 define to use the iCE40 DDR and global-buffer primitives.
//
// Pins (see the XPRO user guide): J100 pin 7 RESET, 15 SPI_SS_A, 16 MOSI, 17 MISO, 18 SCK,
// 20 VCC_TARGET; I/Q on the SATA connectors J101 (RX 2.4 GHz) and J103 (TX) through the
// SN65LVDS049.  Pin 5 / 6 are the two LEDs on the XPRO if you want to drive them.
//
// NOT SIMULATED OR SYNTHESISED when written.

`include "btle_mvp_config.vh"

module btle_mvp_top #(
    // ---- 1. local clock and timing (see the .vh for what each means and when to change it)
    parameter integer CLK_LOCAL_HZ   = `CFG_CLK_LOCAL_HZ,
    parameter integer SPI_HZ         = `CFG_SPI_HZ,
    parameter integer RST_LOW_US     = `CFG_RST_LOW_US,
    parameter integer BOOT_US        = `CFG_BOOT_US,
    parameter integer POLL_MAX       = `CFG_POLL_MAX,
    parameter integer POLL_GAP_US    = `CFG_POLL_GAP_US,
    parameter integer TX_PERIOD_MS   = `CFG_TX_PERIOD_MS,
    parameter integer TX_TIMEOUT_MS  = `CFG_TX_TIMEOUT_MS,
    parameter integer SYNC_US        = `CFG_SYNC_US,
    parameter integer LEAD_US        = `CFG_LEAD_US,
    parameter integer FAULT_RETRY_MS = `CFG_FAULT_RETRY_MS,

    // ---- 2. packet, channel, addresses
    parameter [5:0]       BLE_CHANNEL    = `CFG_BLE_CHANNEL,
    parameter [31:0]      ACCESS_ADDRESS = `CFG_ACCESS_ADDRESS,
    parameter [23:0]      CRC_INIT       = `CFG_CRC_INIT,
    parameter integer     TX_PDU_LEN     = `CFG_TX_PDU_LEN,
    parameter [8*64-1:0]  TX_PDU         = `CFG_TX_PDU,

    // ---- 3. radio registers
    parameter [7:0]  IQIFC0_VAL   = `CFG_IQIFC0_VAL,
    parameter [1:0]  SKEWDRV      = `CFG_SKEWDRV,
    parameter [7:0]  RXDFE_VAL    = `CFG_RXDFE_VAL,
    parameter [7:0]  TXDFE_VAL    = `CFG_TXDFE_VAL,
    parameter        EN_RXBWC     = `CFG_EN_RXBWC,
    parameter [7:0]  RXBWC_VAL    = `CFG_RXBWC_VAL,
    parameter        EN_TXCUTC    = `CFG_EN_TXCUTC,
    parameter [7:0]  TXCUTC_VAL   = `CFG_TXCUTC_VAL,
    parameter        EN_PAC       = `CFG_EN_PAC,
    parameter [7:0]  PAC_VAL      = `CFG_PAC_VAL,
    parameter        EN_SYNC_POLL = `CFG_EN_SYNC_POLL,
    parameter [7:0]  SYNC_MASK    = `CFG_SYNC_MASK,

    // ---- 4. LVDS link
    parameter integer LVDS_RX_LOCK_WORDS = `CFG_LVDS_RX_LOCK_WORDS,
    parameter integer LVDS_RX_MISS_MAX   = `CFG_LVDS_RX_MISS_MAX,
    parameter         LVDS_RX_CHECK_LSB  = `CFG_LVDS_RX_CHECK_LSB,
    parameter         LVDS_RX_INVERT     = `CFG_LVDS_RX_INVERT,
    parameter         LVDS_RX_SWAP_PAIR  = `CFG_LVDS_RX_SWAP_PAIR,
    parameter         LVDS_TX_INVERT     = `CFG_LVDS_TX_INVERT,
    parameter integer LVDS_TX_MIN_IDLE_WORDS = `CFG_LVDS_TX_MIN_IDLE_WORDS,

    // ---- 5. MSK modulator
    parameter [2:0]   MSK_AMP_SHIFT  = `CFG_MSK_AMP_SHIFT,
    parameter         MSK_FREQ_SIGN  = `CFG_MSK_FREQ_SIGN,
    parameter         MSK_PAD_MODE   = `CFG_MSK_PAD_MODE,
    parameter integer MSK_PAD_US     = `CFG_MSK_PAD_US,
    parameter [3:0]   MSK_PHASE_INIT = `CFG_MSK_PHASE_INIT,

    // ---- 6. receive chain and debug output
    parameter integer RX_SAMPLE_PER_SYMBOL = `CFG_RX_SAMPLE_PER_SYMBOL,
    parameter integer RX_IQ_BITS           = `CFG_RX_IQ_BITS,          // 13 to 16
    parameter         RX_NEGATE_Q          = `CFG_RX_NEGATE_Q,
    parameter integer RX_RAM_READ_WAIT     = `CFG_RX_RAM_READ_WAIT,
    parameter         RX_DUMP_BAD_CRC      = `CFG_RX_DUMP_BAD_CRC,
    parameter integer UART_BAUD            = `CFG_UART_BAUD,
    parameter integer LED_STRETCH_MS       = `CFG_LED_STRETCH_MS
)(
    input  wire clk_local,
    input  wire rst_ext,         // optional external reset, active high; tie low if unused

    // AT86RF215 control (XPRO J100)
    output wire rf_rstn,
    output wire rf_seln,
    output wire rf_sclk,
    output wire rf_mosi,
    input  wire rf_miso,

    // I/Q link through the SN65LVDS049
    input  wire rxclk_in,        // ROUT1  (RXCLK), must reach a global clock buffer on an FPGA
    input  wire rxd_in,          // ROUT2  (RXD24)
    output wire txd_out,         // DIN2   (TXD)
    output wire txclk_out,       // DIN1   (TXCLK)

    // debug and status
    output wire uart_txd,
    output wire led_ready,       // radio configured and in the RX/TX loop
    output wire led_fault,       // a check failed; the sequencer is restarting
    output wire led_rx_ok,       // stretched: a packet with a good CRC was received
    output wire led_tx           // stretched: a packet was transmitted
);

    // ------------------------------------------------------------------
    // time and channel conversions
    // ------------------------------------------------------------------
    function integer us2clk;
        input integer us;
        begin
            us2clk = (CLK_LOCAL_HZ / 1000) * us / 1000;
        end
    endfunction

    function integer ms2clk;
        input integer ms;
        begin
            ms2clk = (CLK_LOCAL_HZ / 1000) * ms;
        end
    endfunction

    // BLE channel index -> CCF0 for the radio.  f_MHz: ch37 2402, ch38 2426, ch39 2480,
    // ch0..10 2404 + 2n, ch11..36 2428 + 2(n-11).  CCF0 = (f_MHz - 1500) / 0.025 = (f - 1500) * 40.
    function [15:0] ccf0_of;
        input [5:0] ch;
        integer mhz;
        begin
            if      (ch == 6'd37) mhz = 2402;
            else if (ch == 6'd38) mhz = 2426;
            else if (ch == 6'd39) mhz = 2480;
            else if (ch <= 6'd10) mhz = 2404 + 2 * ch;
            else                  mhz = 2428 + 2 * (ch - 11);
            ccf0_of = (mhz - 1500) * 40;
        end
    endfunction

    localparam integer SPI_HALF_RAW = CLK_LOCAL_HZ / (2 * SPI_HZ);
    localparam integer SPI_HALF     = (SPI_HALF_RAW < 1) ? 1 : SPI_HALF_RAW;
    localparam integer PAD_SAMPLES  = MSK_PAD_US * 4;              // 4 Msps
    localparam [15:0]  CCF0         = ccf0_of(BLE_CHANNEL);

    // crc24_core swaps the first and last seed byte on load (VERIFIED in crc24_core.v); give it
    // the swapped form so CRC_INIT here keeps one meaning for transmit and receive.
    localparam [23:0]  RX_CRC_INIT  = {CRC_INIT[7:0], CRC_INIT[15:8], CRC_INIT[23:16]};

    // ------------------------------------------------------------------
    // resets
    // ------------------------------------------------------------------
    reg [15:0] por_cnt = 16'd0;            // power-on reset; give an ASIC an explicit reset instead
    wire       por_done = &por_cnt;
    always @(posedge clk_local) begin
        if (!por_done) por_cnt <= por_cnt + 16'd1;
    end
    wire rst_local = !por_done | rst_ext;

    wire rst_rx;                           // rxclk domain
    rst_sync u_rst_rx (.clk(rxclk_in), .rst_in(rst_local), .rst_out(rst_rx));

    wire bb_clk, slot;
    bb_clkgen u_bb (.rxclk(rxclk_in), .rst(rst_rx), .bb_clk(bb_clk), .slot(slot));

    wire rst_bb;                           // bb_clk domain
    rst_sync u_rst_bb (.clk(bb_clk), .rst_in(rst_local), .rst_out(rst_bb));

    // ------------------------------------------------------------------
    // radio sequencer (local clock)
    // ------------------------------------------------------------------
    wire stream_en, tx_go, ready, fault;
    wire tx_data_done_l, tx_done_l;

    rf215_init #(
        .RST_LOW_CLKS(us2clk(RST_LOW_US)),
        .BOOT_CLKS(us2clk(BOOT_US)),
        .POLL_MAX(POLL_MAX),
        .POLL_GAP_CLKS(us2clk(POLL_GAP_US)),
        .TX_PERIOD_CLKS(ms2clk(TX_PERIOD_MS)),
        .TX_TIMEOUT_CLKS(ms2clk(TX_TIMEOUT_MS)),
        .SYNC_CLKS(us2clk(SYNC_US)),
        .LEAD_CLKS(us2clk(LEAD_US)),
        .FAULT_CLKS(ms2clk(FAULT_RETRY_MS)),
        .SPI_HALF_PERIOD(SPI_HALF),
        .CCF0(CCF0),
        .IQIFC0_VAL(IQIFC0_VAL),
        .SKEWDRV(SKEWDRV),
        .RXDFE_VAL(RXDFE_VAL),
        .TXDFE_VAL(TXDFE_VAL),
        .EN_RXBWC(EN_RXBWC),
        .RXBWC_VAL(RXBWC_VAL),
        .EN_TXCUTC(EN_TXCUTC),
        .TXCUTC_VAL(TXCUTC_VAL),
        .EN_PAC(EN_PAC),
        .PAC_VAL(PAC_VAL),
        .EN_SYNC_POLL(EN_SYNC_POLL),
        .SYNC_MASK(SYNC_MASK)
    ) u_seq (
        .clk(clk_local), .rst(rst_local),
        .rstn_radio(rf_rstn), .seln(rf_seln), .sclk(rf_sclk), .mosi(rf_mosi), .miso(rf_miso),
        .stream_en(stream_en), .tx_go(tx_go),
        .tx_data_done(tx_data_done_l), .tx_done(tx_done_l),
        .ready(ready), .fault(fault), .listening()
    );

    assign led_ready = ready;
    assign led_fault = fault;

    // ------------------------------------------------------------------
    // transmit chain
    // ------------------------------------------------------------------
    // local -> bb_clk: start request
    wire go_tog;
    pulse2tog u_go_t (.clk(clk_local), .rst(rst_local), .pulse(tx_go), .tog(go_tog));
    wire tx_start_bb;
    tog2pulse u_go_p (.clk(bb_clk), .rst(rst_bb), .tog(go_tog), .pulse(tx_start_bb));

    wire tx_bit, tx_bit_valid, tx_bit_last;
    btle_tx_min #(
        .ACCESS_ADDRESS(ACCESS_ADDRESS),
        .CRC_INIT(CRC_INIT),
        .CHANNEL(BLE_CHANNEL),
        .PDU_LEN(TX_PDU_LEN),
        .PDU(TX_PDU)
    ) u_txb (
        .clk(bb_clk), .rst(rst_bb), .tx_start(tx_start_bb),
        .bit_out(tx_bit), .bit_valid(tx_bit_valid), .bit_last(tx_bit_last), .busy()
    );

    wire signed [12:0] tx_i, tx_q;
    wire msk_data_done, msk_done;
    msk_modulator #(
        .AMP_SHIFT(MSK_AMP_SHIFT),
        .FREQ_SIGN(MSK_FREQ_SIGN),
        .PAD_MODE(MSK_PAD_MODE),
        .PAD_SAMPLES(PAD_SAMPLES),
        .PHASE_INIT(MSK_PHASE_INIT)
    ) u_msk (
        .clk(bb_clk), .rst(rst_bb),
        .bit_in(tx_bit), .bit_valid(tx_bit_valid), .bit_last(tx_bit_last),
        .i_out(tx_i), .q_out(tx_q),
        .data_done(msk_data_done), .done(msk_done), .active()
    );

    // bb_clk -> local: packet samples finished, padding finished
    wire dd_tog, dn_tog;
    pulse2tog u_dd_t (.clk(bb_clk), .rst(rst_bb), .pulse(msk_data_done), .tog(dd_tog));
    pulse2tog u_dn_t (.clk(bb_clk), .rst(rst_bb), .pulse(msk_done),      .tog(dn_tog));
    tog2pulse u_dd_p (.clk(clk_local), .rst(rst_local), .tog(dd_tog), .pulse(tx_data_done_l));
    tog2pulse u_dn_p (.clk(clk_local), .rst(rst_local), .tog(dn_tog), .pulse(tx_done_l));

    lvds_tx #(
        .MIN_IDLE_WORDS(LVDS_TX_MIN_IDLE_WORDS),
        .INVERT(LVDS_TX_INVERT)
    ) u_ltx (
        .rxclk(rxclk_in), .rst(rst_rx), .slot(slot),
        .tx_i(tx_i), .tx_q(tx_q), .tx_ctrl(1'b0), .stream_en(stream_en),
        .txd(txd_out), .txclk(txclk_out), .tx_data_active()
    );

    // ------------------------------------------------------------------
    // receive chain
    // ------------------------------------------------------------------
    wire signed [12:0] rx_i_bb, rx_q_bb;
    wire               rx_valid_bb, rx_lock;

    lvds_rx #(
        .LOCK_WORDS(LVDS_RX_LOCK_WORDS),
        .MISS_MAX(LVDS_RX_MISS_MAX),
        .CHECK_LSB(LVDS_RX_CHECK_LSB),
        .INVERT(LVDS_RX_INVERT),
        .SWAP_PAIR(LVDS_RX_SWAP_PAIR)
    ) u_lrx (
        .rxclk(rxclk_in), .rst(rst_rx), .rxd(rxd_in), .slot(slot),
        .rx_i(), .rx_q(), .rx_valid(), .rx_lock(rx_lock),
        .rx_i_bb(rx_i_bb), .rx_q_bb(rx_q_bb), .rx_valid_bb(rx_valid_bb)
    );

    // Keep btle_rx in reset whenever the I/Q link is not locked.  The radio leaves RX for
    // every transmit burst, and this clears any half-decoded packet left behind.  A reset also
    // clears btle_rx's best_phase (the result-RAM selector), so a dump must finish before the
    // lock drops.  That happens at the next transmit burst, TX_PERIOD_MS later, which is far
    // longer than a dump takes.
    wire rx_lock_bb;
    sync_2ff u_lock_sync (.clk(bb_clk), .d(rx_lock), .q(rx_lock_bb));
    reg rst_btle_rx;
    always @(posedge bb_clk) rst_btle_rx <= rst_bb | ~rx_lock_bb;

    // The radio gives 13-bit samples.  btle_rx takes RX_IQ_BITS (13 to 16); sign-extend to 16
    // bits and keep the low RX_IQ_BITS.  Negating Q mirrors the spectrum; -4096 saturates to 4095.
    wire signed [12:0] rx_q_neg = (rx_q_bb == -13'sd4096) ? 13'sd4095 : -rx_q_bb;
    wire signed [12:0] rx_q_use = RX_NEGATE_Q ? rx_q_neg : rx_q_bb;
    wire signed [15:0] rx_i16   = {{3{rx_i_bb[12]}},  rx_i_bb};
    wire signed [15:0] rx_q16   = {{3{rx_q_use[12]}}, rx_q_use};

    wire       rx_decode_end, rx_crc_ok;
    wire [7:0] rx_payload_length, rx_ram_data;
    wire [8:0] dump_addr;

    btle_rx #(
`ifdef CFG_RX_SET_SPS
        .SAMPLE_PER_SYMBOL(RX_SAMPLE_PER_SYMBOL),
`endif
        .GFSK_DEMODULATION_BIT_WIDTH(RX_IQ_BITS)
    ) u_btle_rx (
        .clk(bb_clk), .rst(rst_btle_rx), .clkb(clk_local),
        .unique_bit_sequence(ACCESS_ADDRESS),
        .channel_number(BLE_CHANNEL),
        .crc_state_init_bit(RX_CRC_INIT),
        .i(rx_i16[RX_IQ_BITS-1:0]), .q(rx_q16[RX_IQ_BITS-1:0]), .iq_valid(rx_valid_bb),
        .pdu_octet_mem_addr(dump_addr),
        .hit_flag(), .decode_run(),
        .decode_end(rx_decode_end), .crc_ok(rx_crc_ok),
        .best_phase(), .payload_length(rx_payload_length),
        .pdu_octet_mem_data(rx_ram_data)
    );

    // Capture the result at decode_end.  In btle_rx, decode_end and crc_ok are set together for
    // one clock, and payload_length is a register that only changes when a phase finishes with a
    // good CRC, so it is valid at decode_end and holds afterwards.  After a failed CRC it still
    // holds the PREVIOUS good packet's length, so the length printed for a BAD packet is stale.
    // The crc_seen flag is belt and braces, not needed by btle_rx as written.
    reg [7:0] cap_len;
    reg       cap_ok;
    reg       crc_seen;
    always @(posedge bb_clk) begin
        if (rst_bb) begin
            cap_len  <= 8'd0;
            cap_ok   <= 1'b0;
            crc_seen <= 1'b0;
        end else begin
            if (rx_crc_ok) crc_seen <= 1'b1;
            if (rx_decode_end) begin
                cap_len  <= rx_payload_length;
                cap_ok   <= crc_seen | rx_crc_ok;
                crc_seen <= 1'b0;
            end
        end
    end

    wire rx_tog;
    pulse2tog u_rx_t (.clk(bb_clk), .rst(rst_bb), .pulse(rx_decode_end), .tog(rx_tog));
    wire rx_evt;
    tog2pulse u_rx_p (.clk(clk_local), .rst(rst_local), .tog(rx_tog), .pulse(rx_evt));

    // cap_len / cap_ok are written before the toggle and stay put until the next packet, so
    // reading them in the local domain after rx_evt is safe.
    pdu_uart_dump #(
        .CLK_HZ(CLK_LOCAL_HZ),
        .BAUD(UART_BAUD),
        .RAM_READ_WAIT(RX_RAM_READ_WAIT),
        .DUMP_BAD_CRC(RX_DUMP_BAD_CRC)
    ) u_dump (
        .clk(clk_local), .rst(rst_local),
        .evt(rx_evt), .len(cap_len), .crc_ok(cap_ok),
        .ram_addr(dump_addr), .ram_data(rx_ram_data),
        .txd(uart_txd), .busy()
    );

    // ------------------------------------------------------------------
    // LEDs
    // ------------------------------------------------------------------
    pulse_stretch #(.CLKS(ms2clk(LED_STRETCH_MS))) u_led_rx (
        .clk(clk_local), .rst(rst_local), .pulse(rx_evt & cap_ok), .out(led_rx_ok));
    pulse_stretch #(.CLKS(ms2clk(LED_STRETCH_MS))) u_led_tx (
        .clk(clk_local), .rst(rst_local), .pulse(tx_go), .out(led_tx));

endmodule
