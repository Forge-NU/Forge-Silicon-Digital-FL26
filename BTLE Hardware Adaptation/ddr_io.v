// ddr_io.v  --  double-data-rate pad cells with an iCE40 version and a generic version
//
//   ddr_in : q_rise is the pad value sampled at the rising edge of clk, q_fall the value
//            sampled at the falling edge (the half cycle after it).  Both are readable at
//            the next rising edge, so a pair {q_rise, q_fall} is one clock cycle of data.
//   ddr_out: d_rise is captured at the rising edge and shown on the pad for the high phase
//            that follows; d_fall is captured at the FALLING edge and shown for the low
//            phase that follows.
//
// iCE40: SB_IO with PIN_TYPE 6'b000000 (DDR input) and 6'b010000 (DDR output), as in
// Lattice TN1253.  The data sheet describes the output side as two registers capturing on
// the positive and negative clock edges followed by a mux, which is what the generic model
// below does.  If a bench measurement ever shows D_OUT_1 behaving as if captured at the
// rising edge, add one rising-edge register stage in front of d_fall.
//
// Define ICE40 to use the primitives.  The generic version is for simulation and as a
// description for an ASIC flow, where a library DDR cell (or a glitch-free clock-phase mux)
// replaces it.

`timescale 1ns/1ps

module ddr_in (
    input  wire clk,
    input  wire pad,
    output wire q_rise,
    output wire q_fall
);
`ifdef ICE40
    SB_IO #(.PIN_TYPE(6'b000000), .PULLUP(1'b0)) u_io (
        .PACKAGE_PIN(pad),
        .INPUT_CLK(clk),
        .D_IN_0(q_rise),
        .D_IN_1(q_fall)
    );
`else
    reg r, f;
    always @(posedge clk) r <= pad;
    always @(negedge clk) f <= pad;
    assign q_rise = r;
    assign q_fall = f;
`endif
endmodule


module ddr_out (
    input  wire clk,
    input  wire d_rise,
    input  wire d_fall,
    output wire pad
);
`ifdef ICE40
    SB_IO #(.PIN_TYPE(6'b010000)) u_io (
        .PACKAGE_PIN(pad),
        .OUTPUT_CLK(clk),
        .D_OUT_0(d_rise),
        .D_OUT_1(d_fall)
    );
`else
    reg q_r, q_f;
    always @(posedge clk) q_r <= d_rise;
    always @(negedge clk) q_f <= d_fall;
    assign pad = clk ? q_r : q_f;
`endif
endmodule
