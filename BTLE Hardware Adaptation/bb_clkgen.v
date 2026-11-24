// bb_clkgen.v  --  baseband clock and crossing strobe from RXCLK
//
// bb_clk = rxclk / 4 (16 MHz from the radio's 64 MHz DDR clock), free-running, so it can
// never produce a runt pulse.  The radio is the I/Q clock master (datasheet 4.5.6): RXCLK
// exists only in TXPREP, TX and RX, so everything on bb_clk is idle in TRXOFF.
//
// `slot` marks the rxclk cycle that sits exactly midway between two bb_clk rising edges.
// Rule for the rxclk-domain modules in this directory:
//   * a register that feeds the bb_clk domain is updated only when slot is high
//   * a register that samples the bb_clk domain does so only when slot is high
// Each such crossing then has two rxclk cycles of setup and two of hold margin, with no
// synchroniser needed, because bb_clk comes from the same counter as slot.
//
// Constraints: create_generated_clock -divide_by 4 on bb_clk, and in an ASIC flow treat
// the slot-gated paths as 2-cycle paths.  On an iCE40, define ICE40 to put bb_clk on a
// global buffer, and put rxclk itself on a global-buffer-capable pin.

module bb_clkgen (
    input  wire rxclk,
    input  wire rst,          // synchronous to rxclk
    output wire bb_clk,
    output wire slot
);
    reg [1:0] c;
    reg       slot_r;
    always @(posedge rxclk) begin
        if (rst) begin
            c      <= 2'd0;
            slot_r <= 1'b0;
        end else begin
            c      <= c + 2'd1;
            slot_r <= (c == 2'd2);       // registered, so it is high exactly while c == 3
        end
    end

    // c = 0,1 -> low; c = 2,3 -> high.  bb_clk rises when c becomes 2.
    // slot is high while c == 3, so registers gated by it update on the edge where c
    // becomes 0, i.e. two rxclk cycles before the next bb_clk rise and two after the last.
    // It comes straight from a flop because it fans out to lvds_rx and lvds_tx at 64 MHz.
    assign slot = slot_r;

`ifdef ICE40
    SB_GB u_gb (.USER_SIGNAL_TO_GLOBAL_BUFFER(c[1]), .GLOBAL_BUFFER_OUTPUT(bb_clk));
`else
    assign bb_clk = c[1];
`endif
endmodule
