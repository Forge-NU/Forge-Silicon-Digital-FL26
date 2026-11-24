`timescale 1ns/1ps
// Silicluster v3 version
// Pins: 8 inputs, 14 outputs (besides clk and rst_n)
// dac_neg is not a pin: it is always ~dac_pos
// result is not a pin: dac_pos holds the finished code while eoc is high
// comp_strobe is not a pin: the comparator is off-chip and continuous-time
module sar_adc_digital #(
    parameter N_MSB         = 6,
    parameter N_LSB         = 6,
    parameter N             = N_MSB + N_LSB,  // 12
    parameter SAMPLE_CYCLES = 2
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,        // tie high for nonstop conversions
    input  wire         comp_out,     // from the comparator
    input  wire [5:0]   div,          // clk cycles per step (2 to 63)
    output wire         sample,       // to the sampling switches
    output wire [N-1:0] dac_pos,      // to the P-side CDAC, and the result when eoc is high
    output wire         eoc           // dac_pos is the finished conversion
);
    wire step, busy;

    bit_timer timer (
        .clk(clk), .rst_n(rst_n), .enable(busy),
        .div({2'b00, div}), .strobe_at(8'd0),
        .step(step), .comp_strobe()
    );

    sar_fsm #(.N_MSB(N_MSB), .N_LSB(N_LSB), .SAMPLE_CYCLES(SAMPLE_CYCLES)) fsm (
        .clk(clk), .rst_n(rst_n), .start(start), .step(step),
        .comp_out(comp_out), .sample(sample), .busy(busy),
        .dac_pos(dac_pos), .dac_neg(),
        .result(), .eoc(eoc)
    );
endmodule
