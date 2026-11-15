// btle_tx_min.v  --  BLE packet to whitened bit stream, 1 bit per 16 clocks
//
// Self-contained replacement for the repo's btle_tx FSM + crc24 + scramble, used so the
// Gaussian filter / upsampler / VCO inside btle_tx are not needed.  It sends:
//     preamble (8 bits), access address (32 bits)       as is
//     PDU bytes, then 24 CRC bits                        whitened
// all least-significant bit first except the CRC, which goes out from LFSR position 23 down.
// Conventions below were fitted to the repo's own README example (PDU 0100, channel 10,
// repo CRC init "123456" -> CRC 9b8950 -> whitened 9bc14d4c14) in btle_tx_check.py, and
// reproduce it exactly.
//
// The packet is a parameter (PDU_LEN bytes, byte 0 at PDU[7:0]); change it at synthesis.
// tx_start starts a transmission; it is ignored while busy.  Timing: bit k is presented with
// bit_valid at clock 16*k after the start, so it needs a 16 MHz bb_clk for 1 Mbit/s.
// Runs in the bb_clk domain.
//
// NOT SIMULATED OR SYNTHESISED when written.

module btle_tx_min #(
    parameter [31:0]       ACCESS_ADDRESS = 32'h8E89BED6,
    // CRC LFSR initial value: position k = bit k of this number.  0x555555 for advertising.
    // The repo's descriptor form is the byte-swapped value, e.g. repo "123456" = 24'h563412.
    parameter [23:0]       CRC_INIT       = 24'h555555,
    parameter [5:0]        CHANNEL        = 6'd37,   // whitening seed, the BLE channel index
    parameter integer      PDU_LEN        = 17,      // bytes, header included, at most 64
    parameter [8*64-1:0]   PDU            = 512'd0   // byte k at PDU[8*k +: 8]
)(
    input  wire clk,          // bb_clk, 16 MHz
    input  wire rst,
    input  wire tx_start,     // one-clock pulse
    output reg  bit_out,
    output reg  bit_valid,    // one clock per bit
    output reg  bit_last,     // with the final CRC bit
    output reg  busy
);

    // advertising: preamble 0xAA when the access address LSB is 0, else 0x55
    localparam [7:0]  PREAMBLE = ACCESS_ADDRESS[0] ? 8'h55 : 8'hAA;
    localparam [39:0] FRAME40  = {ACCESS_ADDRESS, PREAMBLE};     // bit 0 = first on air

    localparam integer N_PDU   = 8 * PDU_LEN;
    localparam integer N_TOTAL = 40 + N_PDU + 24;
    localparam [9:0]   N_PDU10 = 8 * PDU_LEN;

    wire [8*64-1:0] pdu_w = PDU;

    reg [3:0]  ct;
    reg [9:0]  n;
    reg [23:0] crc;
    reg [6:0]  wh;
    reg        fin;

    wire [6:0] wh_init = {CHANNEL[0], CHANNEL[1], CHANNEL[2], CHANNEL[3], CHANNEL[4], CHANNEL[5], 1'b1};

    wire [9:0] pdu_idx = n - 10'd40;
    wire [9:0] crc_idx = n - 10'd40 - N_PDU10;
    wire       in_pre  = (n < 10'd40);
    wire       in_pdu  = !in_pre && (n < (10'd40 + N_PDU10));

    wire       pdu_bit = pdu_w[pdu_idx];
    wire       fb      = pdu_bit ^ crc[23];
    wire       crc_bit = crc[5'd23 - crc_idx[4:0]];
    wire       wh_out  = wh[6];
    wire [6:0] wh_next = {wh[5:0], wh[6]} ^ (wh[6] ? 7'b0010000 : 7'b0000000);

    always @(posedge clk) begin
        bit_valid <= 1'b0;
        bit_last  <= 1'b0;

        if (rst) begin
            busy <= 1'b0;
            fin  <= 1'b0;
            ct   <= 4'd0;
            n    <= 10'd0;
            crc  <= 24'd0;
            wh   <= 7'd0;
        end else if (!busy) begin
            if (tx_start) begin
                busy <= 1'b1;
                fin  <= 1'b0;
                ct   <= 4'd0;
                n    <= 10'd0;
                crc  <= CRC_INIT;
                wh   <= wh_init;
            end
        end else begin
            ct <= ct + 4'd1;

            if (ct == 4'd0) begin
                if (in_pre) begin
                    bit_out <= FRAME40[n[5:0]];
                end else if (in_pdu) begin
                    bit_out <= pdu_bit ^ wh_out;
                    crc     <= {crc[22:0], fb} ^ (fb ? 24'h00065A : 24'h000000);
                    wh      <= wh_next;
                end else begin
                    bit_out <= crc_bit ^ wh_out;
                    wh      <= wh_next;
                end
                bit_valid <= 1'b1;
                bit_last  <= (n == N_TOTAL - 1);
                if (n == N_TOTAL - 1) fin <= 1'b1;
                n <= n + 10'd1;
            end

            if (fin && ct == 4'd15) begin
                busy <= 1'b0;
                fin  <= 1'b0;
            end
        end
    end

endmodule
