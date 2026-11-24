// spi_dbg_slave.v  --  SPI slave register port so the RP2350 can read the FPGA's status
//
// Approach follows the oversampled slave in janschiefer/verilog_spi (spi_module.v, LGPL-2.1,
// used as a reference only, no code copied): SCK, CS and MOSI are sampled with the system clock,
// edges are detected in logic, mode 0 (MOSI sampled on rising SCK, MISO changed on falling SCK),
// MSB first, 8-bit words.  Differences: 2-flop synchronisers on all inputs, and CS frames
// every transfer (CS high resets the bit counter, so a glitch cannot misalign later frames).
//
// Protocol (one frame per CS low):
//   byte 0 from master : {W, A[6:0]}   W = 1 write, 0 read; A = start register
//   byte 0 on MISO     : 0xA5          (link check)
//   read  : following bytes on MISO are reg[A], reg[A+1], ...   (MOSI ignored)
//   write : following bytes on MOSI are written to reg[A], reg[A+1], ...
// Register contents come from rd_data (combinational mux of rd_addr in the parent);
// writes come out as wr_stb / wr_addr / wr_data, one clk pulse per byte.
//
// SCK must stay below clk / 6 (2 MHz with the 12 MHz clk_local) for the edge detector.

module spi_dbg_slave (
    input  wire       clk,
    input  wire       rst,
    input  wire       sck,        // asynchronous
    input  wire       csn,
    input  wire       mosi,
    output reg        miso,

    output wire [6:0] rd_addr,
    input  wire [7:0] rd_data,
    output reg        wr_stb,
    output reg  [6:0] wr_addr,
    output reg  [7:0] wr_data
);
    localparam [7:0] MARKER = 8'hA5;

    reg [2:0] sck_s;
    reg [1:0] cs_s, mosi_s;
    always @(posedge clk) begin
        sck_s  <= {sck_s[1:0], sck};
        cs_s   <= {cs_s[0], csn};
        mosi_s <= {mosi_s[0], mosi};
    end
    wire sck_rise  = sck_s[1] & ~sck_s[2];
    wire sck_fall  = ~sck_s[1] & sck_s[2];
    wire cs_active = ~cs_s[1];
    wire din       = mosi_s[1];          // same delay as sck_s[1]

    reg [2:0] bitcnt;
    reg [7:0] rx_sr;
    reg [7:0] tx_sr;
    reg       first;                     // receiving the command byte
    reg       wr_mode;
    reg [6:0] addr;
    reg       load;                      // next falling edge starts a new transmit byte

    assign rd_addr = addr;
    wire [7:0] rx_byte = {rx_sr[6:0], din};

    always @(posedge clk) begin
        wr_stb <= 1'b0;
        if (rst || !cs_active) begin
            // idle: armed for the next frame, MISO shows the marker's MSB
            bitcnt <= 3'd0;
            first  <= 1'b1;
            load   <= 1'b0;
            tx_sr  <= MARKER;
            miso   <= MARKER[7];
        end else begin
            if (sck_rise) begin
                rx_sr  <= rx_byte;
                bitcnt <= bitcnt + 3'd1;
                if (bitcnt == 3'd7) begin                 // byte complete
                    load <= 1'b1;
                    if (first) begin
                        first   <= 1'b0;
                        wr_mode <= rx_byte[7];
                        addr    <= rx_byte[6:0];
                    end else begin
                        if (wr_mode) begin
                            wr_stb  <= 1'b1;
                            wr_addr <= addr;
                            wr_data <= rx_byte;
                        end
                        addr <= addr + 7'd1;
                    end
                end
            end
            if (sck_fall) begin
                if (load) begin                           // first bit of the next byte
                    load  <= 1'b0;
                    tx_sr <= rd_data;                     // reg[addr]
                    miso  <= rd_data[7];
                end else begin
                    tx_sr <= {tx_sr[6:0], 1'b0};
                    miso  <= tx_sr[6];
                end
            end
        end
    end
endmodule
