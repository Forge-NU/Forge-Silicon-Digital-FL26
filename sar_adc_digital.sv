`timescale 1ns/1ps
// sar_adc_digital: connects bit_timer (when to move) to sar_fsm (what to do)
module sar_adc_digital (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,        // begin a conversion
    input  logic        comp_out,     // from the comparator
    input  logic [7:0]  div,          // clk cycles per step
    input  logic [7:0]  strobe_at,    // when the comparator decides in each step
    output logic        sample,       // to the sampling switches
    output logic        comp_strobe,  // to the comparator
    output logic [11:0] dac_pos,      // to the CDAC, P side
    output logic [11:0] dac_neg,      // to the CDAC, N side
    output logic [11:0] result,       // finished conversion
    output logic        eoc           // result is ready
);
    logic step, busy;

    bit_timer timer (
        .clk(clk), .rst_n(rst_n), .enable(busy),
        .div(div), .strobe_at(strobe_at),
        .step(step), .comp_strobe(comp_strobe)
    );

    sar_fsm fsm (
        .clk(clk), .rst_n(rst_n), .start(start), .step(step),
        .comp_out(comp_out), .sample(sample), .busy(busy),
        .result(result), .dac_pos(dac_pos), .dac_neg(dac_neg), .eoc(eoc)
    );
endmodule
