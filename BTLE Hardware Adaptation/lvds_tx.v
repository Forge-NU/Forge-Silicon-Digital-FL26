// lvds_tx.v  --  AT86RF215 I/Q transmit link: word build and DDR serialiser
//
// Outputs go to the SN65LVDS049 driver inputs (DIN2 = TXD, DIN1 = TXCLK).  The radio is the
// clock master and expects TXCLK to be a copy of RXCLK (datasheet 4.5.7), so everything here
// runs on rxclk and TXCLK is generated from it.  rxclk exists only in TXPREP, TX and RX.
//
// Word format (datasheet 4.5.4):
//   [31:30] I_SYNC = 0b10   [29:17] I_DATA[13:1] = tx_i   [16] I_DATA[0] = tx_ctrl
//   [15:14] Q_SYNC = 0b01   [13:1]  Q_DATA[13:1] = tx_q   [0]  Q_DATA[0]  = 0
// Edge alignment (4.5.3, Figure 4-10): the radio wants TXD edge-aligned with TXCLK, bit 31
// launched with a rising edge, bit 30 with the falling edge, and so on.  TXCLK is sent as the
// DDR pattern {1,0}, so data and clock leave the same pad cells on the same clock.
// Skew tolerated at the radio input: data relative to clock -1 ns to +2 ns (Table 10-35).
//
// Link rules enforced here (4.5.6):
//   * zero words (32 zero bits) whenever stream_en is low
//   * the first data word follows at least MIN_IDLE_WORDS zero words (>= 1 gives the 32 zero
//     bits needed for initial sync; 10 gives the 2.5 us between bursts)
//   * once started, data words follow back to back, one per 16 rxclk cycles (4 Mword/s)
// When stream_en is high the link sends data words built from tx_i/tx_q.  Zero-amplitude
// samples are valid data words; the radio only transmits when told to by SPI or by tx_ctrl.
//
// DDR timing: the iCE40 DDR output captures its falling-edge input at the falling edge, so
// the odd bits run one cycle ahead of the even bits (see lvds_framing_model.py, TxSerializer,
// 200 cold-start loopback runs with no errors).
//
// Inputs from the bb_clk domain (tx_i, tx_q, tx_ctrl) are sampled only when `slot` is high.
// stream_en comes from the sequencer's local clock and is synchronised here.
// NOT SIMULATED OR SYNTHESISED when written.

module lvds_tx #(
    parameter MIN_IDLE_WORDS = 10,
    parameter INVERT         = 0       // 1 if the differential data pair is wired swapped
)(
    input  wire               rxclk,
    input  wire               rst,           // synchronous to rxclk
    input  wire               slot,          // from bb_clkgen
    input  wire signed [12:0] tx_i,          // bb_clk domain
    input  wire signed [12:0] tx_q,
    input  wire               tx_ctrl,       // I_DATA[0]; 0 unless embedded TX control is used
    input  wire               stream_en,     // local clock domain, synchronised here

    output wire               txd,           // to the SN65LVDS049 (DIN2)
    output wire               txclk,         // to the SN65LVDS049 (DIN1)
    output reg                tx_data_active // high while data words (not idle zeros) are sent
);

    reg [1:0]  en_sync;
    reg signed [12:0] i_r, q_r;
    reg        ctrl_r;

    always @(posedge rxclk) begin
        en_sync <= {en_sync[0], stream_en};
        if (slot) begin
            i_r    <= tx_i;
            q_r    <= tx_q;
            ctrl_r <= tx_ctrl;
        end
    end

    wire en = en_sync[1];

    reg [3:0]  wc;           // clock cycle within the word, 0..15
    reg [31:0] sh;
    reg        d_rise;
    reg        d_fall;
    reg [7:0]  idle_cnt;     // zero words sent since the last data word, saturating

    wire        last      = (wc == 4'd15);
    wire        send_data = en && (idle_cnt >= MIN_IDLE_WORDS);
    wire [31:0] data_word = {2'b10, i_r, ctrl_r, 2'b01, q_r, 1'b0};
    wire [31:0] nw        = send_data ? data_word : 32'd0;

    always @(posedge rxclk) begin
        if (rst) begin
            wc             <= 4'd0;
            sh             <= 32'd0;
            d_rise         <= 1'b0;
            d_fall         <= 1'b0;
            idle_cnt       <= 8'd0;
            tx_data_active <= 1'b0;
        end else begin
            // at edge k: d_fall <= B_k = bit[30-2k],  d_rise <= A_(k+1) = bit[29-2k];
            // on the last edge A_0 of the next word comes from nw
            d_fall <= sh[31] ^ INVERT[0];
            d_rise <= (last ? nw[31] : sh[30]) ^ INVERT[0];
            sh     <= last ? {nw[30:0], 1'b0} : {sh[29:0], 2'b00};
            wc     <= wc + 4'd1;

            if (last) begin
                tx_data_active <= send_data;
                if (send_data)            idle_cnt <= 8'd0;
                else if (idle_cnt != 8'hFF) idle_cnt <= idle_cnt + 8'd1;
            end
        end
    end

    ddr_out u_txd   (.clk(rxclk), .d_rise(d_rise), .d_fall(d_fall), .pad(txd));
    ddr_out u_txclk (.clk(rxclk), .d_rise(1'b1),   .d_fall(1'b0),   .pad(txclk));

endmodule
