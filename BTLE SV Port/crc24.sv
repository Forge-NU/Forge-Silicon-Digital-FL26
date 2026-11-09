// Author: Xianjun Jiao <putaoshu@msn.com>
// SPDX-FileCopyrightText: 2024 Xianjun Jiao
// SPDX-License-Identifier: Apache-2.0 license

// Core_v5.3 figure3.4 on page 2734
// Assume clk speed 16M, info_bit 1M, info_bit_valid every 16 clk
// CRC operation skips the 40 bits at the beginning (preamble+access_address)

`timescale 1ns / 1ps
module crc24 #
(
  parameter integer NUM_BIT_PAYLOAD_LENGTH = 8, // 8 bit in the core spec 6.2
  parameter integer CRC_STATE_BIT_WIDTH = 24
) (
  input logic clk,
  input logic rst,

  input  logic [(CRC_STATE_BIT_WIDTH-1) : 0] crc_state_init_bit, // load into lfsr (linear feedback shift register) upon crc_state_init_bit_load==1
  input  logic crc_state_init_bit_load,
  input  logic info_bit,
  input  logic info_bit_valid,
  input  logic info_bit_valid_last, // if this is true together with valid, it means last bit input
  output logic info_bit_after_crc24,
  output logic info_bit_after_crc24_valid,
  output logic info_bit_after_crc24_valid_last // indicate last bit out together with info_bit_after_crc24_valid
);

localparam [1:0] IDLE           = 0,
                 WORK_ON_INPUT  = 1,
                 CRC_BIT_OUTPUT = 2;

logic [1:0] crc_state;

logic [(CRC_STATE_BIT_WIDTH-1) : 0] lfsr;

logic info_bit_valid_internal;
logic [(NUM_BIT_PAYLOAD_LENGTH+3+1):0] info_bit_count;  // 1 more addr bit is needed: the octet_valid actually will output 2 bytes header, payload length, 3 bytes CRC
logic [4:0] crc_bit_count;
logic [3:0] clk_count;

assign info_bit_valid_internal = (info_bit_count>=40? info_bit_valid : 0);

always_ff @ (posedge clk) begin
  if (rst) begin
    info_bit_after_crc24 <= 0;
    info_bit_after_crc24_valid <= 0;
    info_bit_after_crc24_valid_last <= 0;

    info_bit_count <= 0;
    crc_bit_count <= 0;
    clk_count <= 0;

    crc_state <= IDLE;
  end else begin
    case(crc_state)
      IDLE: begin
        info_bit_after_crc24 <= info_bit;
        info_bit_after_crc24_valid <= info_bit_valid;

        crc_bit_count <= 0;
        clk_count <= 0;

        info_bit_after_crc24_valid_last <= 0;

        info_bit_count <= (info_bit_valid ? (info_bit_count+1) : info_bit_count);

        crc_state <= (info_bit_valid ? WORK_ON_INPUT : crc_state);
      end

      WORK_ON_INPUT: begin
        info_bit_after_crc24 <= info_bit;
        info_bit_after_crc24_valid <= info_bit_valid;

        info_bit_count <= (info_bit_valid ? (info_bit_count+1) : info_bit_count);

        crc_state <= (info_bit_valid_last ? CRC_BIT_OUTPUT : crc_state);
      end
      
      CRC_BIT_OUTPUT: begin
        clk_count <= clk_count + 1;
        if (clk_count == 15) begin
          crc_bit_count <= crc_bit_count + 1;
          info_bit_after_crc24 <= lfsr[23-crc_bit_count];
          info_bit_after_crc24_valid <= 1;
          if (crc_bit_count == 23) begin
            info_bit_after_crc24_valid_last <= 1;

            info_bit_count <= 0;

            crc_state <= IDLE;
          end
        end else begin
          info_bit_after_crc24_valid <= 0;
          info_bit_after_crc24_valid_last <= 0;
        end
      end
    endcase
  end
end

crc24_core # (
  .CRC_STATE_BIT_WIDTH(CRC_STATE_BIT_WIDTH)
) crc24_core_i (
  .clk(clk),
  .rst(rst),

  .crc_state_init_bit(crc_state_init_bit),
  .crc_state_init_bit_load(crc_state_init_bit_load),
  .data_in(info_bit),
  .data_in_valid(info_bit_valid_internal),

  .lfsr(lfsr)
);

endmodule
