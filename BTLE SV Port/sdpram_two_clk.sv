// Author: Xianjun Jiao <putaoshu@msn.com>
// SPDX-FileCopyrightText: 2025 Xianjun Jiao
// SPDX-License-Identifier: Apache-2.0 license

// Based on Xilinx UG901 2025-06-11
// https://docs.amd.com/r/en-US/ug901-vivado-synthesis/Simple-Dual-Port-Block-RAM-with-Single-Clock-Verilog
// Simple Dual-Port Block RAM with Dual Clocks (Verilog)

`timescale 1ns / 1ps
module sdpram_two_clk #
(
  parameter integer DATA_WIDTH = 8,
  parameter integer ADDRESS_WIDTH = 11
) (
  input logic clk,
  input logic rst,

  input logic [ADDRESS_WIDTH-1:0] write_address,
  input logic [DATA_WIDTH-1:0] write_data,
  input logic write_enable,

  input logic clkb,
  input logic [ADDRESS_WIDTH-1:0] read_address,
  output logic [DATA_WIDTH-1:0] read_data
);

logic [DATA_WIDTH-1:0] memory [((1<<ADDRESS_WIDTH)-1):0];

// Write logic (Port A)
always_ff @ (posedge clk) begin
  if (write_enable) begin
    memory[write_address] <= write_data;
  end
end

// Read logic (Port B)
always_ff @ (posedge clkb) begin
  read_data <= memory[read_address];
end

endmodule
