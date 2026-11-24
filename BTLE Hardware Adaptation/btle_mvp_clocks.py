# btle_mvp_clocks.py  --  nextpnr-ice40 --pre-pack clock constraints for btle_mvp_pico2ice
#   clk_local : 12 MHz from the RP2350 (CFG_CLK_LOCAL_HZ)
#   rxclk_in  : 64 MHz DDR clock from the AT86RF215 via the SN65LVDS049
#   bb_clk    : rxclk / 4 = 16 MHz, made in bb_clkgen and put on a global buffer (SB_GB)
ctx.addClock("clk_local", 12)
ctx.addClock("rxclk_in", 64)
ctx.addClock("u_top.u_bb.bb_clk", 16)
