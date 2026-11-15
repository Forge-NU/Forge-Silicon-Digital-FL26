// rf215_init.v
//
// Replaces the microcontroller's role for the AT86RF215 (2.4 GHz, I/Q radio mode):
//   1. reset the radio, check it answers over SPI and is a part with a 2.4 GHz radio
//   2. configure I/Q interface, BLE channel, 4 Msps in and out, TX power
//   3. bring it to RX
//   4. every TX_PERIOD_CLKS: TXPREP, start the I/Q stream, TX, packet, TXPREP, RX
//   5. on any failed check or timeout: raise `fault`, wait, reset the radio, restart
//
// A program counter walks a ROM of steps (function `rom`); an engine turns each
// step into one 24-bit SPI transaction or a wait.
//
// STATUS: checked against the AT86RF215 datasheet (Atmel-42415E, 05/2016) but
// NOT SIMULATED OR SYNTHESISED when written.  Datasheet references are to
// that document's section numbers.
//
// CLOCKING: this module runs on a LOCAL clock that exists even in TRXOFF.  The
// radio is the I/Q clock master (RXCLK exists only in TXPREP, TX, RX), so the
// baseband (btle_tx, lvds_tx, btle_rx, lvds_rx) must run from RXCLK.  The
// handshake signals below (tx_go, stream_en, tx_data_done, tx_done) therefore
// cross clock domains and need toggle/pulse synchronisers in the top level.
//
// VERIFIED against the datasheet:
//   SPI: 2 command bytes (00 read / 10 write + 14-bit address) + data byte, MSB
//        first, SELN low per access, clocks a multiple of 8, MOSI sampled on
//        rising SCLK, MISO updated on falling SCLK, fSCLK <= 25 MHz (4.2, 10.12)
//   Registers: RF_PN 000D, IQIFC0/1/2 000A/B/C, RF24_STATE 0202, CMD 0203,
//        CS 0204, CCF0L/H 0205/6, CNL 0207, CNM 0208, RXBWC 0209, RXDFE 020A,
//        TXCUTC 0212, TXDFE 0213, PAC 0214 (register summary, section 8)
//   Command/state codes: TRXOFF 2, TXPREP 3, TX 4, RX 5 (5.2.10)
//   Channel: f = (CCF0 + CN*CS)*25 kHz + 1.5 GHz for RF24, CM=0, CNM written last (6.3.2)
//   IQIFC1: CHPM=1 is I/Q radio mode, SKEWDRV is 2 bits, reset 0x02 (4.5.8.2)
//   IQIFC0: CMV1V2=1 selects 1.2 V common mode for IEEE 1596 LVDS (4.5.2)
//   Part numbers: 0x34 AT86RF215, 0x35 AT86RF215IQ, 0x36 AT86RF215M (1.1.3.1)

module rf215_init #(
    // ---- timing, in clk cycles (defaults assume a 16 MHz clk)
    parameter RST_LOW_CLKS    = 1600,       // RSTN low; datasheet minimum is 625 ns
    parameter BOOT_CLKS       = 1600,       // after RSTN release; datasheet max 1 us to TRXOFF
    parameter POLL_MAX        = 4096,       // tries per status poll
    parameter POLL_GAP_CLKS   = 16,
    parameter TX_PERIOD_CLKS  = 1600000,    // about 100 ms between bursts
    parameter TX_TIMEOUT_CLKS = 160000,     // give up waiting on the TX datapath
    parameter SYNC_CLKS       = 800,        // 50 us for TX link start-up and word sync
    parameter LEAD_CLKS       = 320,        // 20 us after CMD=TX before the packet
                                            //  (ttx_start_delay 4 us + PA ramp 4 us default)
    parameter FAULT_CLKS      = 1600000,
    parameter SPI_HALF_PERIOD = 2,          // SCLK = clk/4 = 4 MHz
    // ---- radio configuration
    // CCF0 = (f_MHz - 1500) / 0.025.  BLE advertising channels:
    //   ch37 2402 MHz = 16'h8CF0,  ch38 2426 MHz = 16'h90B0,  ch39 2480 MHz = 16'h9920
    parameter [15:0] CCF0       = 16'h8CF0,
    // IQIFC0: reset 0x14.  0x36 = CMV1V2 (1.2 V common mode for a standard LVDS
    // part such as the SN65LVDS049), DRV=3 (4 mA), CMV unchanged, EEC=0 (TX start
    // and stop by SPI).  EEC=1 would let the I/Q stream control TX instead.
    parameter [7:0]  IQIFC0_VAL = 8'h36,
    parameter [1:0]  SKEWDRV    = 2'd2,     // reset value: data centre-aligned to RXCLK
    // RCUT 3 = 0.75 * fs/2 = 1.5 MHz, SR 1 = 4 Msps
    parameter [7:0]  RXDFE_VAL  = 8'h61,
    // RCUT 4 = 1.0 * fs/2 = TX pre-filter bypassed (lowest delay), SR 1 = 4 Msps
    parameter [7:0]  TXDFE_VAL  = 8'h81,
    // Reset values are usable and are left alone unless enabled:
    //   RXBWC reset 0x0B = 2000 kHz,  TXCUTC reset 0x08 = LPFCUT 500 kHz, PARAMP 4 us
    parameter        EN_RXBWC   = 0,
    parameter [7:0]  RXBWC_VAL  = 8'h0B,
    parameter        EN_TXCUTC  = 0,
    parameter [7:0]  TXCUTC_VAL = 8'h08,
    // PAC reset 0x7F = maximum power (datasheet: up to +14 dBm).  0x71 = TXPWR 17,
    // about 1 dB per step, so roughly 0 dBm.  ESTIMATE: check Figure 11-3.
    parameter        EN_PAC     = 1,
    parameter [7:0]  PAC_VAL    = 8'h71,
    // IQIFC2.SYNC is set when the radio has received an I/Q data word.  It is
    // only meaningful while stream_en is sending words.
    parameter        EN_SYNC_POLL = 0,
    parameter [7:0]  SYNC_MASK  = 8'h80
)(
    input  wire clk,
    input  wire rst,                        // synchronous, active high

    // radio pins
    output wire rstn_radio,                 // to RSTN, active low
    output wire seln,
    output wire sclk,
    output wire mosi,
    input  wire miso,

    // handshake with the TX datapath (all single clk-wide pulses unless noted)
    output reg  stream_en,                  // level: send zero-amplitude I/Q words (TX link sync)
    output reg  tx_go,                      // start the packet
    input  wire tx_data_done,               // packet samples finished, padding begins
    input  wire tx_done,                    // padding finished, stream may stop

    // status
    output wire ready,                      // init finished, in the RX/TX loop
    output reg  fault,                      // a check failed; auto-restarts
    output wire listening                   // radio is in RX waiting for the next TX
);

    // ------------------------------------------------------------------
    // constants
    // ------------------------------------------------------------------
    localparam [3:0] OP_WR          = 4'd0,
                     OP_POLL        = 4'd1,
                     OP_PN          = 4'd2,
                     OP_WAIT_PERIOD = 4'd3,
                     OP_TX_GO       = 4'd4,
                     OP_JUMP        = 4'd5,
                     OP_NOP         = 4'd6,
                     OP_WAIT_DATA   = 4'd7,
                     OP_WAIT_DONE   = 4'd8,
                     OP_STREAM_ON   = 4'd9,
                     OP_STREAM_OFF  = 4'd10,
                     OP_WAIT_SYNC   = 4'd11,
                     OP_WAIT_LEAD   = 4'd12;

    localparam [13:0] A_IQIFC0 = 14'h000A,
                      A_IQIFC1 = 14'h000B,
                      A_IQIFC2 = 14'h000C,
                      A_PN     = 14'h000D,
                      A_STATE  = 14'h0202,
                      A_CMD    = 14'h0203,
                      A_CS     = 14'h0204,
                      A_CCF0L  = 14'h0205,
                      A_CCF0H  = 14'h0206,
                      A_CNL    = 14'h0207,
                      A_CNM    = 14'h0208,
                      A_RXBWC  = 14'h0209,
                      A_RXDFE  = 14'h020A,
                      A_TXCUTC = 14'h0212,
                      A_TXDFE  = 14'h0213,
                      A_PAC    = 14'h0214;

    localparam [7:0] CMD_TRXOFF = 8'h02,
                     CMD_TXPREP = 8'h03,
                     CMD_TX     = 8'h04,
                     CMD_RX     = 8'h05;
    localparam [7:0] ST_MASK    = 8'h07;

    localparam [5:0] LOOP_IDX = 6'd18;      // index of OP_WAIT_PERIOD below

    // ------------------------------------------------------------------
    // program ROM: {op[3:0], addr[13:0], data[7:0], mask[7:0]}  (34 bits)
    // ------------------------------------------------------------------
    function [33:0] rom;
        input [5:0] i;
        begin
            case (i)
                // ---- one-time bring-up
                6'd0:  rom = {OP_PN,   A_PN,     8'h00, 8'h00};
                6'd1:  rom = {OP_POLL, A_STATE,  CMD_TRXOFF, ST_MASK};
                6'd2:  rom = {OP_WR,   A_IQIFC0, IQIFC0_VAL, 8'h00};
                6'd3:  rom = {OP_WR,   A_IQIFC1, {1'b0, 3'd1, 2'b00, SKEWDRV}, 8'h00}; // CHPM=1
                6'd4:  rom = {OP_WR,   A_CS,     8'h08, 8'h00};
                6'd5:  rom = {OP_WR,   A_CCF0L,  CCF0[7:0],  8'h00};
                6'd6:  rom = {OP_WR,   A_CCF0H,  CCF0[15:8], 8'h00};
                6'd7:  rom = {OP_WR,   A_CNL,    8'h00, 8'h00};
                6'd8:  rom = {OP_WR,   A_CNM,    8'h00, 8'h00};                       // CM=0; written last
                6'd9:  rom = EN_RXBWC  ? {OP_WR, A_RXBWC,  RXBWC_VAL,  8'h00} : {OP_NOP, 14'd0, 16'h0000};
                6'd10: rom = {OP_WR,   A_RXDFE,  RXDFE_VAL, 8'h00};
                6'd11: rom = EN_TXCUTC ? {OP_WR, A_TXCUTC, TXCUTC_VAL, 8'h00} : {OP_NOP, 14'd0, 16'h0000};
                6'd12: rom = {OP_WR,   A_TXDFE,  TXDFE_VAL, 8'h00};
                6'd13: rom = EN_PAC    ? {OP_WR, A_PAC,    PAC_VAL,    8'h00} : {OP_NOP, 14'd0, 16'h0000};
                6'd14: rom = {OP_WR,   A_CMD,    CMD_TXPREP, 8'h00};
                6'd15: rom = {OP_POLL, A_STATE,  CMD_TXPREP, ST_MASK};
                6'd16: rom = {OP_WR,   A_CMD,    CMD_RX, 8'h00};
                6'd17: rom = {OP_POLL, A_STATE,  CMD_RX, ST_MASK};
                // ---- repeating loop
                6'd18: rom = {OP_WAIT_PERIOD, 14'd0, 16'h0000};                       // listen
                6'd19: rom = {OP_WR,   A_CMD,    CMD_TXPREP, 8'h00};
                6'd20: rom = {OP_POLL, A_STATE,  CMD_TXPREP, ST_MASK};
                6'd21: rom = {OP_STREAM_ON,  14'd0, 16'h0000};                        // send zero words
                6'd22: rom = {OP_WAIT_SYNC,  14'd0, 16'h0000};                        // link start-up + sync
                6'd23: rom = EN_SYNC_POLL ? {OP_POLL, A_IQIFC2, SYNC_MASK, SYNC_MASK} : {OP_NOP, 14'd0, 16'h0000};
                6'd24: rom = {OP_WR,   A_CMD,    CMD_TX, 8'h00};
                6'd25: rom = {OP_POLL, A_STATE,  CMD_TX, ST_MASK};
                6'd26: rom = {OP_WAIT_LEAD,  14'd0, 16'h0000};                        // PA start delay + ramp
                6'd27: rom = {OP_TX_GO,      14'd0, 16'h0000};                        // packet starts
                6'd28: rom = {OP_WAIT_DATA,  14'd0, 16'h0000};                        // packet samples done
                6'd29: rom = {OP_WR,   A_CMD,    CMD_TXPREP, 8'h00};                  // PA ramps down
                6'd30: rom = {OP_POLL, A_STATE,  CMD_TXPREP, ST_MASK};
                6'd31: rom = {OP_WAIT_DONE,  14'd0, 16'h0000};                        // padding covers ramp
                6'd32: rom = {OP_STREAM_OFF, 14'd0, 16'h0000};
                6'd33: rom = {OP_WR,   A_CMD,    CMD_RX, 8'h00};
                6'd34: rom = {OP_POLL, A_STATE,  CMD_RX, ST_MASK};
                default: rom = {OP_JUMP, 14'd0, {2'b00, LOOP_IDX}, 8'h00};
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // engine
    // ------------------------------------------------------------------
    localparam [3:0] S_RST_LOW     = 4'd0,
                     S_BOOT        = 4'd1,
                     S_FETCH       = 4'd2,
                     S_SPI_START   = 4'd3,
                     S_SPI_WAIT    = 4'd4,
                     S_EVAL        = 4'd5,
                     S_GAP         = 4'd6,
                     S_WAIT_PERIOD = 4'd7,
                     S_WAIT_CLKS   = 4'd8,
                     S_WAIT_DATA   = 4'd9,
                     S_WAIT_DONE   = 4'd10,
                     S_FAULT       = 4'd11;

    reg [3:0]  state;
    reg [5:0]  pc;
    reg [3:0]  op_r;
    reg [13:0] addr_r;
    reg [7:0]  data_r;
    reg [7:0]  mask_r;
    reg [31:0] timer;
    reg [31:0] wait_lim;
    reg [12:0] poll_cnt;
    reg        rstn_r;
    reg        got_data_done;
    reg        got_done;

    reg         spi_start;
    reg  [23:0] spi_tx;
    wire [7:0]  spi_rx;
    wire        spi_done;
    wire        spi_busy;

    wire [33:0] rom_word   = rom(pc);
    wire [3:0]  rom_op     = rom_word[33:30];
    wire        op_is_read = (op_r == OP_POLL) || (op_r == OP_PN);

    spi_master #(.HALF_PERIOD(SPI_HALF_PERIOD)) u_spi (
        .clk(clk), .rst(rst),
        .start(spi_start), .tx_word(spi_tx),
        .rx_byte(spi_rx), .busy(spi_busy), .done(spi_done),
        .seln(seln), .sclk(sclk), .mosi(mosi), .miso(miso)
    );

    assign rstn_radio = rstn_r;
    assign ready      = (pc >= LOOP_IDX) && !fault;
    assign listening  = (state == S_WAIT_PERIOD);

    always @(posedge clk) begin
        tx_go     <= 1'b0;
        spi_start <= 1'b0;

        // latch the TX datapath pulses so a pulse that arrives while an SPI
        // transaction is in flight is not lost
        if (tx_data_done) got_data_done <= 1'b1;
        if (tx_done)      got_done      <= 1'b1;

        if (rst) begin
            state         <= S_RST_LOW;
            pc            <= 6'd0;
            timer         <= 32'd0;
            wait_lim      <= 32'd0;
            poll_cnt      <= 13'd0;
            rstn_r        <= 1'b0;
            fault         <= 1'b0;
            stream_en     <= 1'b0;
            got_data_done <= 1'b0;
            got_done      <= 1'b0;
            op_r          <= OP_NOP;
            addr_r        <= 14'd0;
            data_r        <= 8'd0;
            mask_r        <= 8'd0;
            spi_tx        <= 24'd0;
        end else begin
            case (state)

                S_RST_LOW: begin
                    rstn_r <= 1'b0;
                    if (timer == RST_LOW_CLKS) begin
                        rstn_r <= 1'b1;
                        timer  <= 32'd0;
                        state  <= S_BOOT;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                S_BOOT: begin
                    if (timer == BOOT_CLKS) begin
                        timer <= 32'd0;
                        pc    <= 6'd0;
                        state <= S_FETCH;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                S_FETCH: begin
                    op_r     <= rom_op;
                    addr_r   <= rom_word[29:16];
                    data_r   <= rom_word[15:8];
                    mask_r   <= rom_word[7:0];
                    poll_cnt <= 13'd0;
                    timer    <= 32'd0;
                    case (rom_op)
                        OP_WR, OP_POLL, OP_PN: state <= S_SPI_START;
                        OP_NOP:         pc <= pc + 6'd1;
                        OP_WAIT_PERIOD: state <= S_WAIT_PERIOD;
                        OP_WAIT_SYNC: begin
                            wait_lim <= SYNC_CLKS;
                            state    <= S_WAIT_CLKS;
                        end
                        OP_WAIT_LEAD: begin
                            wait_lim <= LEAD_CLKS;
                            state    <= S_WAIT_CLKS;
                        end
                        OP_WAIT_DATA:  state <= S_WAIT_DATA;
                        OP_WAIT_DONE:  state <= S_WAIT_DONE;
                        OP_STREAM_ON: begin
                            stream_en <= 1'b1;
                            pc        <= pc + 6'd1;
                        end
                        OP_STREAM_OFF: begin
                            stream_en <= 1'b0;
                            pc        <= pc + 6'd1;
                        end
                        OP_TX_GO: begin
                            tx_go         <= 1'b1;
                            got_data_done <= 1'b0;
                            got_done      <= 1'b0;
                            pc            <= pc + 6'd1;
                        end
                        OP_JUMP: pc <= rom_word[13:8];
                        default: pc <= pc + 6'd1;
                    endcase
                end

                S_SPI_START: begin
                    spi_tx    <= op_is_read ? {2'b00, addr_r, 8'h00}
                                            : {2'b10, addr_r, data_r};
                    spi_start <= 1'b1;
                    state     <= S_SPI_WAIT;
                end

                S_SPI_WAIT: begin
                    if (spi_done) state <= S_EVAL;
                end

                S_EVAL: begin
                    case (op_r)
                        OP_WR: begin
                            pc    <= pc + 6'd1;
                            state <= S_FETCH;
                        end
                        OP_PN: begin
                            // 0x34 = AT86RF215, 0x35 = AT86RF215IQ.  0x36 is the
                            // sub-GHz-only AT86RF215M and has no 2.4 GHz radio.
                            if (spi_rx == 8'h34 || spi_rx == 8'h35) begin
                                pc    <= pc + 6'd1;
                                state <= S_FETCH;
                            end else begin
                                fault     <= 1'b1;
                                stream_en <= 1'b0;
                                timer     <= 32'd0;
                                state     <= S_FAULT;
                            end
                        end
                        OP_POLL: begin
                            if ((spi_rx & mask_r) == data_r) begin
                                pc    <= pc + 6'd1;
                                state <= S_FETCH;
                            end else if (poll_cnt == POLL_MAX) begin
                                fault     <= 1'b1;
                                stream_en <= 1'b0;
                                timer     <= 32'd0;
                                state     <= S_FAULT;
                            end else begin
                                poll_cnt <= poll_cnt + 13'd1;
                                timer    <= 32'd0;
                                state    <= S_GAP;
                            end
                        end
                        default: state <= S_FETCH;
                    endcase
                end

                S_GAP: begin
                    if (timer == POLL_GAP_CLKS) state <= S_SPI_START;
                    else timer <= timer + 32'd1;
                end

                S_WAIT_PERIOD: begin
                    if (timer == TX_PERIOD_CLKS) begin
                        pc    <= pc + 6'd1;
                        state <= S_FETCH;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                S_WAIT_CLKS: begin
                    if (timer == wait_lim) begin
                        pc    <= pc + 6'd1;
                        state <= S_FETCH;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                S_WAIT_DATA: begin
                    if (got_data_done) begin
                        pc    <= pc + 6'd1;
                        state <= S_FETCH;
                    end else if (timer == TX_TIMEOUT_CLKS) begin
                        fault     <= 1'b1;
                        stream_en <= 1'b0;
                        timer     <= 32'd0;
                        state     <= S_FAULT;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                S_WAIT_DONE: begin
                    if (got_done) begin
                        pc    <= pc + 6'd1;
                        state <= S_FETCH;
                    end else if (timer == TX_TIMEOUT_CLKS) begin
                        fault     <= 1'b1;
                        stream_en <= 1'b0;
                        timer     <= 32'd0;
                        state     <= S_FAULT;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                S_FAULT: begin
                    if (timer == FAULT_CLKS) begin
                        fault  <= 1'b0;
                        pc     <= 6'd0;
                        timer  <= 32'd0;
                        rstn_r <= 1'b0;
                        state  <= S_RST_LOW;
                    end else begin
                        timer <= timer + 32'd1;
                    end
                end

                default: state <= S_RST_LOW;
            endcase
        end
    end

endmodule
