// Author: Xianjun Jiao <putaoshu@msn.com>
// SPDX-FileCopyrightText: 2024 Xianjun Jiao
// SPDX-License-Identifier: Apache-2.0 license

// MODIFIED: made SAMPLE_PER_SYMBOL values below 8 work (needed for 4 Msps I/Q, 4 sampling
// phases).  The original only worked at 8 because the phase counter wrapped at 8 and several
// array accesses were written out for exactly 8 phases.  Behaviour at SAMPLE_PER_SYMBOL = 8 is
// unchanged.  Changes: (1) iq_phase wraps at SAMPLE_PER_SYMBOL, (2) payload_length_store_wire
// is built with a generate loop, (3) the 8-way best-phase case became a loop, (4) the 8-way
// output selector became a loop.  Compile this file INSTEAD of btle_rx.v.
// iverilog -o btle_rx btle_rx.v btle_rx_core.v gfsk_demodulation.v search_unique_bit_sequence.v scramble_core.v crc24_core.v serial_in_ram_out.v sdpram_two_clk.v

`define KEEP_FOR_DBG (*mark_debug="true",DONT_TOUCH="TRUE"*)

`timescale 1ns / 1ps
module btle_rx #
(
  parameter integer SAMPLE_PER_SYMBOL = 8,
  parameter integer GFSK_DEMODULATION_BIT_WIDTH = 16,
  parameter integer LEN_UNIQUE_BIT_SEQUENCE = 32,
  parameter integer CHANNEL_NUMBER_BIT_WIDTH = 6,
  parameter integer CRC_STATE_BIT_WIDTH = 24,
  parameter integer NUM_BIT_PAYLOAD_LENGTH = 8 // 8 bit in the core spec 6.2
) (
  input wire clk, // for baseband processing, 16MHz
  input wire rst,

  input wire clkb, // for reading pkt from ram with different/higher clock speed

  input wire [(LEN_UNIQUE_BIT_SEQUENCE-1) : 0] unique_bit_sequence,
  input wire [(CHANNEL_NUMBER_BIT_WIDTH-1) : 0] channel_number,
  input wire [(CRC_STATE_BIT_WIDTH-1) : 0] crc_state_init_bit,

  `KEEP_FOR_DBG input wire signed [(GFSK_DEMODULATION_BIT_WIDTH-1) : 0] i,
  `KEEP_FOR_DBG input wire signed [(GFSK_DEMODULATION_BIT_WIDTH-1) : 0] q,
  `KEEP_FOR_DBG input wire iq_valid,

  output wire hit_flag,
  output reg  decode_run,
  output reg  decode_end,
  output reg  crc_ok,
  output reg  [2:0] best_phase,
  
  output reg  [(NUM_BIT_PAYLOAD_LENGTH-1):0] payload_length,

  output reg  [7:0] pdu_octet_mem_data,
  `KEEP_FOR_DBG input  wire [NUM_BIT_PAYLOAD_LENGTH:0] pdu_octet_mem_addr
);

// state machine output decode end
localparam [0:0] IDLE                     = 0,
                 WAIT_DECODE_END_LONGEST  = 1;

`KEEP_FOR_DBG reg signed [(GFSK_DEMODULATION_BIT_WIDTH-1) : 0] i_store [0 : (SAMPLE_PER_SYMBOL-1)];
`KEEP_FOR_DBG reg signed [(GFSK_DEMODULATION_BIT_WIDTH-1) : 0] q_store [0 : (SAMPLE_PER_SYMBOL-1)];
`KEEP_FOR_DBG reg [(SAMPLE_PER_SYMBOL-1) : 0] iq_valid_store;
`KEEP_FOR_DBG reg [2:0] iq_phase;

`KEEP_FOR_DBG wire [(SAMPLE_PER_SYMBOL-1) : 0] hit_flag_internal;
`KEEP_FOR_DBG wire [(NUM_BIT_PAYLOAD_LENGTH-1):0] payload_length_internal [0 : (SAMPLE_PER_SYMBOL-1)];
`KEEP_FOR_DBG wire [(SAMPLE_PER_SYMBOL-1) : 0] payload_length_valid;
`KEEP_FOR_DBG wire [(SAMPLE_PER_SYMBOL-1) : 0] bit_internal;
`KEEP_FOR_DBG wire [(SAMPLE_PER_SYMBOL-1) : 0] bit_valid;
`KEEP_FOR_DBG wire [7:0] octet_internal [0 : (SAMPLE_PER_SYMBOL-1)];
`KEEP_FOR_DBG wire [(SAMPLE_PER_SYMBOL-1) : 0] octet_valid;
`KEEP_FOR_DBG wire [(SAMPLE_PER_SYMBOL-1) : 0] decode_end_internal;
`KEEP_FOR_DBG wire [(SAMPLE_PER_SYMBOL-1) : 0] crc_ok_internal;

// reg  [5:0] addr_internal [0 : (SAMPLE_PER_SYMBOL-1)];
`KEEP_FOR_DBG wire [7:0] data_internal [0 : (SAMPLE_PER_SYMBOL-1)];

`KEEP_FOR_DBG reg  [(NUM_BIT_PAYLOAD_LENGTH-1):0] payload_length_store [0 : (SAMPLE_PER_SYMBOL-1)];
`KEEP_FOR_DBG reg  [(SAMPLE_PER_SYMBOL-1) : 0] crc_ok_store;
`KEEP_FOR_DBG reg  [(SAMPLE_PER_SYMBOL-1) : 0] decode_end_store;
`KEEP_FOR_DBG reg  [(SAMPLE_PER_SYMBOL-1) : 0] decode_end_store_effective; // for those sub-decoders never hit, they should be treated as decode end already
`KEEP_FOR_DBG wire [(SAMPLE_PER_SYMBOL-1) : 0] decode_end_and_crc_ok_store;
`KEEP_FOR_DBG reg  [(SAMPLE_PER_SYMBOL-1) : 0] hit_flag_all_phase;

wire [(NUM_BIT_PAYLOAD_LENGTH-1):0] payload_length_store_wire [0 : (SAMPLE_PER_SYMBOL-1)];

`KEEP_FOR_DBG wire hit_flag_any;
`KEEP_FOR_DBG reg  hit_flag_any_delay;
`KEEP_FOR_DBG wire decode_end_all;
// `KEEP_FOR_DBG wire decode_end_any;
`KEEP_FOR_DBG wire decode_end_early;

// reg       timeout_count_enable;
// reg [3:0] timeout_count_sample;
`KEEP_FOR_DBG reg [0:0] decode_end_state;
`KEEP_FOR_DBG reg decode_restart;

genvar gen_pl;
generate
  for (gen_pl=0; gen_pl<SAMPLE_PER_SYMBOL; gen_pl=gen_pl+1) begin : gen_payload_length_wire
    assign payload_length_store_wire[gen_pl] = payload_length_store[gen_pl];
  end
endgenerate

assign hit_flag_any = (|hit_flag_all_phase);
assign decode_end_all = (&decode_end_store_effective);
// assign decode_end_any = (|decode_end_store);
assign decode_end_and_crc_ok_store = (decode_end_store_effective&crc_ok_store);
assign decode_end_early = (|decode_end_and_crc_ok_store);

assign hit_flag = (hit_flag_any==1 && hit_flag_any_delay==0);

// output interface
integer sel_idx;
always @ (posedge clk) begin
  if (rst) begin
    decode_run <= 0;
    hit_flag_any_delay <= 0;
    decode_end <= 0;
    crc_ok <= 0;
    best_phase <= 0;
    payload_length <= 0;

    decode_end_store_effective <= 0;

    decode_restart <= 0;

    decode_end_state <= IDLE;
    // timeout_count_sample <= 0;
    // timeout_count_enable <= 0;
  end else begin
    decode_restart <= decode_end;

    hit_flag_any_delay <= hit_flag_any;

    if (hit_flag) begin
      decode_run <= 1;
    end else if (decode_end) begin
      decode_run <= 0;
    end

    // exactly one phase finished with a good CRC: remember which one (same rule as the original
    // 8-way case, written as a loop so it also works for SAMPLE_PER_SYMBOL < 8)
    if ((decode_end_and_crc_ok_store != 0) &&
        ((decode_end_and_crc_ok_store & (decode_end_and_crc_ok_store - 1)) == 0)) begin
      for (sel_idx=0; sel_idx<SAMPLE_PER_SYMBOL; sel_idx=sel_idx+1) begin
        if (decode_end_and_crc_ok_store[sel_idx]) begin
          best_phase <= sel_idx;
          payload_length <= payload_length_store_wire[sel_idx];
        end
      end
    end

    case(decode_end_state)
      IDLE: begin
        decode_end <= 0;
        crc_ok <= 0;
        decode_end_store_effective <= 0;
        // timeout_count_sample <= 0;
        // timeout_count_enable <= 0;
        decode_end_state <= (hit_flag? WAIT_DECODE_END_LONGEST : decode_end_state);
      end

      WAIT_DECODE_END_LONGEST: begin
        // timeout_count_enable <= (decode_end_any == 1? 1 : timeout_count_enable);
        // timeout_count_sample <= ( (iq_valid && timeout_count_enable)? (timeout_count_sample+1) : timeout_count_sample);
        decode_end_store_effective <= (decode_end_store | (~hit_flag_all_phase));

        if (decode_end_early) begin
          decode_end <= 1;
          crc_ok <= 1;
          decode_end_state <= IDLE;
        // end else if (timeout_count_sample == SAMPLE_PER_SYMBOL) begin // issue decode_end_any happens much earlier than the correct decode_end&crc_ok, this case will terminate the whole rx too early!
        end else if (decode_end_all) begin // worse case, all decoder runs to the end without crc_ok
          decode_end <= 1;
          decode_end_state <= IDLE;
        end
      end

    endcase

  end
end

// output selector
integer mux_idx;
always @* begin
  pdu_octet_mem_data = 8'h00;
  for (mux_idx=0; mux_idx<SAMPLE_PER_SYMBOL; mux_idx=mux_idx+1) begin
    if (best_phase == mux_idx) pdu_octet_mem_data = data_internal[mux_idx];
  end
end

// distribute sample into all 8 phases
integer idx;
always @ (posedge clk) begin
  if (rst) begin
    iq_valid_store <= 0;
    iq_phase <= 0;
    // generate
      for (idx=0; idx<SAMPLE_PER_SYMBOL; idx = idx + 1) begin
        i_store[idx] <= 0;
        q_store[idx] <= 0;
      end
    // endgenerate
  end else begin
    if (iq_valid) begin
      iq_phase <= (iq_phase == (SAMPLE_PER_SYMBOL-1)) ? 3'd0 : (iq_phase + 3'd1);
      i_store[iq_phase] <= i;
      q_store[iq_phase] <= q;
      iq_valid_store <= (1<<iq_phase);
    end else begin
      iq_valid_store <= 0;
    end
  end
end

genvar gen_idx;
generate
  for (gen_idx=0; gen_idx<SAMPLE_PER_SYMBOL; gen_idx=gen_idx+1) begin
    btle_rx_core # (
      .GFSK_DEMODULATION_BIT_WIDTH(GFSK_DEMODULATION_BIT_WIDTH),
      .LEN_UNIQUE_BIT_SEQUENCE(LEN_UNIQUE_BIT_SEQUENCE),
      .CHANNEL_NUMBER_BIT_WIDTH(CHANNEL_NUMBER_BIT_WIDTH),
      .CRC_STATE_BIT_WIDTH(CRC_STATE_BIT_WIDTH),
      .NUM_BIT_PAYLOAD_LENGTH(NUM_BIT_PAYLOAD_LENGTH)
    ) btle_rx_core_i (
      .clk(clk),
      .rst(rst|decode_end_early|decode_end_all),

      .unique_bit_sequence(unique_bit_sequence),
      .channel_number(channel_number),
      .crc_state_init_bit(crc_state_init_bit),

      .i(i_store[gen_idx]),
      .q(q_store[gen_idx]),
      .iq_valid(iq_valid_store[gen_idx]),

      .hit_flag(hit_flag_internal[gen_idx]),
      .payload_length_out(payload_length_internal[gen_idx]),
      .payload_length_valid(payload_length_valid[gen_idx]),

      .info_bit(bit_internal[gen_idx]),
      .bit_valid(bit_valid[gen_idx]),

      .octet(octet_internal[gen_idx]),
      .octet_valid(octet_valid[gen_idx]),

      .decode_end(decode_end_internal[gen_idx]),
      .crc_ok(crc_ok_internal[gen_idx])
    );

    serial_in_ram_out # ( // 1 more addr bit is needed: the octet_valid actually will output 2 bytes header, payload length, 3 bytes CRC
      .DATA_WIDTH(8),
      .ADDRESS_WIDTH(NUM_BIT_PAYLOAD_LENGTH+1)
    ) serial_in_ram_out_i (
      .clk(clk),
      .rst(rst|hit_flag_internal[gen_idx]),

      .data_in(octet_internal[gen_idx]),
      .data_in_valid(octet_valid[gen_idx]),

      .clkb(clkb),
      .addr(pdu_octet_mem_addr),
      .data(data_internal[gen_idx])
    );

    always @ (posedge clk) begin
      if (rst|hit_flag_internal[gen_idx]) begin
        payload_length_store[gen_idx] <= 0;
      end else if (payload_length_valid[gen_idx]) begin
        payload_length_store[gen_idx] <= payload_length_internal[gen_idx];
      end
    end

    always @ (posedge clk) begin
      // if (rst|hit_flag_internal[gen_idx]|decode_end_early|decode_end_all) begin
      if (rst|hit_flag_internal[gen_idx]|decode_restart) begin
        crc_ok_store[gen_idx] <= 0;
        decode_end_store[gen_idx] <= 0;
      end else if (decode_end_internal[gen_idx]) begin
        crc_ok_store[gen_idx] <= crc_ok_internal[gen_idx];
        decode_end_store[gen_idx] <= 1;
      end
    end

    always @ (posedge clk) begin
      if (rst|decode_end_internal[gen_idx]|decode_end_early|decode_end_all) begin
        hit_flag_all_phase[gen_idx] <= 0;
      end else if (hit_flag_internal[gen_idx]) begin
        hit_flag_all_phase[gen_idx] <= 1;
      end
    end
  end
endgenerate

endmodule
