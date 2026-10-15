module sar_adc_digital #(
    parameter int N             = 12,
    parameter int SAMPLE_CYCLES = 2
)(
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,        // tie high for nonstop conversions
    input  logic         comp_out,     // from the comparator
    input  logic [7:0]   div,          // clk cycles per step
    input  logic [7:0]   strobe_at,    // comparator decision point within a step
    output logic         sample,       // to the sampling switch
    output logic         comp_strobe,  // to the comparator
    output logic [N-1:0] dac_code,     // to the CDAC
    output logic [N-1:0] result,       // finished conversion
    output logic         eoc           // result is new
);
    logic step, busy;

    bit_timer timer (
        .clk(clk), .rst_n(rst_n), .enable(busy),
        .div(div), .strobe_at(strobe_at),
        .step(step), .comp_strobe(comp_strobe)
    );

    sar_fsm #(.N(N), .SAMPLE_CYCLES(SAMPLE_CYCLES)) fsm (
        .clk(clk), .rst_n(rst_n), .start(start), .step(step),
        .comp_out(comp_out), .sample(sample), .busy(busy),
        .dac_code(dac_code), .result(result), .eoc(eoc)
    );
endmodule
