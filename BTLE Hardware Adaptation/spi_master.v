// spi_master.v
//
// SPI master, mode 0 (CPOL=0, CPHA=0), MSB first, SELN active low.
// One fixed 24-bit transaction per start pulse:
//     bytes 0..1 : COMMAND (2-bit mode + 14-bit address)
//     byte  2    : data written (write) or data returned on MISO (read)
// This matches the AT86RF215 single-register access format.
//
// SCLK frequency = clk / (2 * HALF_PERIOD).
// NOT SIMULATED OR SYNTHESISED when this file was written.

module spi_master #(
    parameter HALF_PERIOD = 2          // clk cycles per SCLK half period (1..255)
)(
    input  wire        clk,
    input  wire        rst,            // synchronous, active high
    input  wire        start,          // one-clock pulse, ignored unless idle
    input  wire [23:0] tx_word,
    output reg  [7:0]  rx_byte,        // last 8 bits seen on MISO, valid with done
    output reg         busy,
    output reg         done,           // one-clock pulse at end of transaction
    output reg         seln,
    output reg         sclk,
    output reg         mosi,
    input  wire        miso
);

    localparam [2:0] S_IDLE  = 3'd0,
                     S_SETUP = 3'd1,
                     S_HIGH  = 3'd2,
                     S_LOW   = 3'd3,
                     S_HOLD  = 3'd4;

    reg [2:0]  state;
    reg [23:0] sh_out;
    reg [23:0] sh_in;
    reg [4:0]  bit_cnt;
    reg [7:0]  div_cnt;

    wire tick = (div_cnt == (HALF_PERIOD - 1));

    always @(posedge clk) begin
        done <= 1'b0;

        if (rst) begin
            state   <= S_IDLE;
            seln    <= 1'b1;
            sclk    <= 1'b0;
            mosi    <= 1'b0;
            busy    <= 1'b0;
            div_cnt <= 8'd0;
            bit_cnt <= 5'd0;
            sh_out  <= 24'd0;
            sh_in   <= 24'd0;
            rx_byte <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    div_cnt <= 8'd0;
                    if (start) begin
                        sh_out  <= tx_word;
                        bit_cnt <= 5'd0;
                        busy    <= 1'b1;
                        seln    <= 1'b0;
                        mosi    <= tx_word[23];
                        state   <= S_SETUP;
                    end
                end

                // SELN low and first bit on MOSI for one half period
                // before the first rising edge.
                S_SETUP: begin
                    if (tick) begin
                        div_cnt <= 8'd0;
                        sclk    <= 1'b1;
                        sh_in   <= {sh_in[22:0], miso};
                        state   <= S_HIGH;
                    end else begin
                        div_cnt <= div_cnt + 8'd1;
                    end
                end

                S_HIGH: begin
                    if (tick) begin
                        div_cnt <= 8'd0;
                        sclk    <= 1'b0;
                        if (bit_cnt == 5'd23) begin
                            state <= S_HOLD;
                        end else begin
                            bit_cnt <= bit_cnt + 5'd1;
                            sh_out  <= {sh_out[22:0], 1'b0};
                            mosi    <= sh_out[22];
                            state   <= S_LOW;
                        end
                    end else begin
                        div_cnt <= div_cnt + 8'd1;
                    end
                end

                S_LOW: begin
                    if (tick) begin
                        div_cnt <= 8'd0;
                        sclk    <= 1'b1;
                        sh_in   <= {sh_in[22:0], miso};
                        state   <= S_HIGH;
                    end else begin
                        div_cnt <= div_cnt + 8'd1;
                    end
                end

                // One half period after the last falling edge, release SELN.
                S_HOLD: begin
                    if (tick) begin
                        div_cnt <= 8'd0;
                        seln    <= 1'b1;
                        busy    <= 1'b0;
                        done    <= 1'b1;
                        rx_byte <= sh_in[7:0];
                        state   <= S_IDLE;
                    end else begin
                        div_cnt <= div_cnt + 8'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
