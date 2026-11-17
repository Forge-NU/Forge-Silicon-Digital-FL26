// btle_tx_fpga_top.sv
//
// Standalone FPGA top level around btle_tx, for synthesis / place-and-route
// checks and first bring-up. No SPI or radio needed: everything btle_tx needs
// is loaded on-chip after power-up:
//   - Gaussian filter taps (BT = 0.5, 8 samples/bit, same values as the testbenches)
//   - cos/sin tables, copied from one sine ROM (sin_table.hex): cos[a] = sin[a + 512]
//   - an advertising packet (ADV_NONCONN_IND, name "ICE40") on channel 37
// Then it transmits that packet over and over, every TX_INTERVAL clocks.
//
// The 8-bit I/Q goes to the PMOD pins for now. Later this is replaced by the
// 4 MS/s conversion + LVDS serializer to the AT86RF215.
//
// Build note: sin_table.hex must be in the folder you run yosys from.

`timescale 1ns / 1ps
`default_nettype none

module btle_tx_fpga_top #(
  parameter int TX_INTERVAL = 1600000   // 100 ms at 16 MHz
) (
  input  logic              clk,          // pin 35: clock from the RP2350 (16 MHz expected)
  output logic signed [7:0] i_out,        // PMOD A (FPGA-only pins)
  output logic signed [7:0] q_out,        // PMOD B (FPGA-only pins)
  output logic              led_g,        // FPGA RGB LED, driven through SB_RGBA_DRV
  output logic              led_b,
  output logic              led_r
);

  // ---------------- power-on reset ----------------
  // iCE40 flip-flops start at 0 after configuration
  logic [7:0] por_count = 8'd0;
  logic       rst;
  always_ff @(posedge clk)
    if (por_count != 8'hFF) por_count <= por_count + 8'd1;
  assign rst = (por_count != 8'hFF);

  // ---------------- packet contents ----------------
  localparam int PDU_LEN = 18;

  function automatic logic [7:0] pdu_byte(input logic [4:0] idx);
    case (idx)
      5'd0:  pdu_byte = 8'h42;  // header: ADV_NONCONN_IND, TxAdd = random
      5'd1:  pdu_byte = 8'h10;  // payload length = 16
      5'd2:  pdu_byte = 8'h06;  // AdvA C1:02:03:04:05:06, LSB first
      5'd3:  pdu_byte = 8'h05;
      5'd4:  pdu_byte = 8'h04;
      5'd5:  pdu_byte = 8'h03;
      5'd6:  pdu_byte = 8'h02;
      5'd7:  pdu_byte = 8'hC1;
      5'd8:  pdu_byte = 8'h02;  // Flags AD: len 2, type 01, value 06
      5'd9:  pdu_byte = 8'h01;
      5'd10: pdu_byte = 8'h06;
      5'd11: pdu_byte = 8'h06;  // Complete Local Name AD: len 6, type 09, "ICE40"
      5'd12: pdu_byte = 8'h09;
      5'd13: pdu_byte = 8'h49;  // I
      5'd14: pdu_byte = 8'h43;  // C
      5'd15: pdu_byte = 8'h45;  // E
      5'd16: pdu_byte = 8'h34;  // 4
      5'd17: pdu_byte = 8'h30;  // 0
      default: pdu_byte = 8'h00;
    endcase
  endfunction

  function automatic logic signed [15:0] tap_val(input logic [3:0] k);
    case (k)
      4'd3:  tap_val = 16'sd1;
      4'd4:  tap_val = 16'sd4;
      4'd5:  tap_val = 16'sd9;
      4'd6:  tap_val = 16'sd15;
      4'd7:  tap_val = 16'sd22;
      4'd8:  tap_val = 16'sd26;
      default: tap_val = 16'sd0;
    endcase
  endfunction

  // ---------------- sine ROM (block RAM) ----------------
  logic [7:0]  sin_rom [0:2047];
  initial $readmemh("sin_table.hex", sin_rom);

  logic [10:0] tbl_addr;   // which table entry the loader is on
  logic        tbl_sel;    // 0 = filling sin table, 1 = filling cos table
  logic        tbl_go;     // loader is producing entries
  logic [10:0] rom_addr;
  logic [7:0]  rom_q;
  logic [10:0] s1_addr;
  logic        s1_sel;
  logic        s1_go;

  assign rom_addr = tbl_sel ? (tbl_addr + 11'd512) : tbl_addr;  // cos(x) = sin(x + 90 deg)

  always_ff @(posedge clk) begin
    rom_q   <= sin_rom[rom_addr];
    s1_addr <= tbl_addr;
    s1_sel  <= tbl_sel;
    s1_go   <= tbl_go;
  end

  // Table write ports (the VCO's table RAMs write every clock, so these hold
  // their last value when loading is done, which just rewrites that entry)
  logic [10:0]       sin_wa, cos_wa;
  logic signed [7:0] sin_wd, cos_wd;

  always_ff @(posedge clk) begin
    if (rst) begin
      sin_wa <= '0; sin_wd <= '0;
      cos_wa <= '0; cos_wd <= 8'sd127;   // entry 0 of cos is 127
    end else if (s1_go) begin
      if (s1_sel == 1'b0) begin sin_wa <= s1_addr; sin_wd <= rom_q; end
      else                begin cos_wa <= s1_addr; cos_wd <= rom_q; end
    end
  end

  // ---------------- loader / transmit state machine ----------------
  typedef enum logic [2:0] {
    S_TAPS, S_TABLES, S_DRAIN, S_PDU, S_CONFIG, S_START, S_TX, S_WAIT
  } state_t;

  state_t      state;
  logic [4:0]  idx;
  logic [21:0] timer;

  logic [3:0]         tap_index;
  logic signed [15:0] tap_value;
  logic [8:0]         pdu_addr;
  logic [7:0]         pdu_data;
  logic               crc_load;
  logic               ch_load;
  logic               tx_start;
  logic               iq_valid;
  logic               iq_valid_last;

  always_ff @(posedge clk) begin
    if (rst) begin
      state     <= S_TAPS;
      idx       <= '0;
      timer     <= '0;
      tap_index <= 4'd15;      // 15 = not a tap, writes nothing
      tap_value <= '0;
      tbl_addr  <= '0;
      tbl_sel   <= 1'b0;
      tbl_go    <= 1'b0;
      pdu_addr  <= 9'd511;     // unused address
      pdu_data  <= '0;
      crc_load  <= 1'b0;
      ch_load   <= 1'b0;
      tx_start  <= 1'b0;
    end else begin
      crc_load <= 1'b0;
      ch_load  <= 1'b0;
      tx_start <= 1'b0;

      case (state)
        // Gaussian taps 0..8
        S_TAPS: begin
          tap_index <= idx[3:0];
          tap_value <= tap_val(idx[3:0]);
          idx       <= idx + 5'd1;
          if (idx == 5'd8) begin
            idx    <= '0;
            tbl_go <= 1'b1;
            state  <= S_TABLES;
          end
        end

        // sin table entries 0..2047, then cos table entries 0..2047
        S_TABLES: begin
          tap_index <= 4'd15;
          tbl_addr  <= tbl_addr + 11'd1;
          if (tbl_addr == 11'd2047) begin
            if (tbl_sel == 1'b0) begin
              tbl_sel <= 1'b1;
            end else begin
              tbl_go <= 1'b0;
              state  <= S_DRAIN;
            end
          end
        end

        // let the last table writes finish
        S_DRAIN: begin
          idx <= idx + 5'd1;
          if (idx == 5'd7) begin
            idx   <= '0;
            state <= S_PDU;
          end
        end

        // packet bytes into btle_tx's PDU RAM
        S_PDU: begin
          pdu_addr <= {4'd0, idx};
          pdu_data <= pdu_byte(idx);
          idx      <= idx + 5'd1;
          if (idx == PDU_LEN - 1) begin
            idx   <= '0;
            state <= S_CONFIG;
          end
        end

        // reload CRC init and channel before every packet
        S_CONFIG: begin
          pdu_addr <= 9'd511;  // park the RAM write port
          pdu_data <= 8'h00;
          crc_load <= 1'b1;
          ch_load  <= 1'b1;
          state    <= S_START;
        end

        S_START: begin
          tx_start <= 1'b1;
          state    <= S_TX;
        end

        S_TX: begin
          if (iq_valid_last) begin
            timer <= '0;
            state <= S_WAIT;
          end
        end

        S_WAIT: begin
          timer <= timer + 22'd1;
          if (timer == TX_INTERVAL - 1)
            state <= S_CONFIG;
        end

        default: state <= S_TAPS;
      endcase
    end
  end

  // ---------------- status LED ----------------
  // red   = still loading (stuck here = loader problem)
  // green = toggles once per packet: blinks at ~5 Hz with a 16 MHz clock
  //         (slower or faster blinking means the clock is not 16 MHz)
  // blue  = off
  logic loaded = 1'b0;
  logic pkt_toggle = 1'b0;
  always_ff @(posedge clk) begin
    if (state == S_CONFIG) loaded <= 1'b1;
    if (state == S_TX && iq_valid_last) pkt_toggle <= ~pkt_toggle;
  end

  // The LED pins (39, 40, 41) are the iCE40's dedicated RGB current drivers
  SB_RGBA_DRV #(
    .CURRENT_MODE ("0b1"),        // half-current mode
    .RGB0_CURRENT ("0b000001"),   // lowest current: plenty bright
    .RGB1_CURRENT ("0b000001"),
    .RGB2_CURRENT ("0b000001")
  ) rgb_drv (
    .CURREN   (1'b1),
    .RGBLEDEN (1'b1),
    .RGB0PWM  (loaded & pkt_toggle),  // RGB0 = pin 39 = green
    .RGB1PWM  (1'b0),                 // RGB1 = pin 40 = blue
    .RGB2PWM  (~loaded),              // RGB2 = pin 41 = red
    .RGB0     (led_g),
    .RGB1     (led_b),
    .RGB2     (led_r)
  );

  // ---------------- the transmitter ----------------
  btle_tx btle_tx_i (
    .clk                      (clk),
    .rst                      (rst),
    .clkb                     (clk),       // PDU RAM written from the same clock here

    .gauss_filter_tap_index   (tap_index),
    .gauss_filter_tap_value   (tap_value),

    .cos_table_write_address  (cos_wa),
    .cos_table_write_data     (cos_wd),
    .sin_table_write_address  (sin_wa),
    .sin_table_write_data     (sin_wd),

    .preamble                 (8'hAA),
    .access_address           (32'h8E89BED6),  // advertising access address
    .crc_state_init_bit       (24'h555555),    // advertising CRC init
    .crc_state_init_bit_load  (crc_load),
    .channel_number           (6'd37),
    .channel_number_load      (ch_load),

    .pdu_octet_mem_data       (pdu_data),
    .pdu_octet_mem_addr       (pdu_addr),

    .tx_start                 (tx_start),

    .i                        (i_out),
    .q                        (q_out),
    .iq_valid                 (iq_valid),
    .iq_valid_last            (iq_valid_last),

    // debug outputs left unconnected: synthesis removes them
    .phy_bit                              (),
    .phy_bit_valid                        (),
    .phy_bit_valid_last                   (),
    .bit_upsample                         (),
    .bit_upsample_valid                   (),
    .bit_upsample_valid_last              (),
    .bit_upsample_gauss_filter            (),
    .bit_upsample_gauss_filter_valid      (),
    .bit_upsample_gauss_filter_valid_last ()
  );


endmodule

`default_nettype wire
