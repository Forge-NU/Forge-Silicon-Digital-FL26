`timescale 1ns/1ps
module sar_adc_digital #(
    parameter int N_MSB         = 6,
    parameter int N_LSB         = 6,
    parameter int N             = N_MSB + N_LSB,  // 12
    parameter int SAMPLE_CYCLES = 2
)(
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,        // tie high for nonstop conversions
    input  logic         comp_out,     // from the comparator
    input  logic [7:0]   div,          // clk cycles per step
    input  logic [7:0]   strobe_at,    // comparator decision point within a step
    output logic         sample,       // to the sampling switches
    output logic         comp_strobe,  // to the comparator
    output logic [N-1:0] dac_pos,      // to the P-side CDAC
    output logic [N-1:0] dac_neg,      // to the N-side CDAC
    output logic [N-1:0] result,       // finished conversion
    output logic         eoc           // result is new
);
    logic step, busy;

    bit_timer timer (
        .clk(clk), .rst_n(rst_n), .enable(busy),
        .div(div), .strobe_at(strobe_at),
        .step(step), .comp_strobe(comp_strobe)
    );

    sar_fsm #(.N_MSB(N_MSB), .N_LSB(N_LSB), .SAMPLE_CYCLES(SAMPLE_CYCLES)) fsm (
        .clk(clk), .rst_n(rst_n), .start(start), .step(step),
        .comp_out(comp_out), .sample(sample), .busy(busy),
        .dac_pos(dac_pos), .dac_neg(dac_neg),
        .result(result), .eoc(eoc)
    );
endmodule
