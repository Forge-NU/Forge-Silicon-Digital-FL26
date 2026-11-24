// btle_mvp_pico2ice.v  --  pico2-ice board top for btle_mvp_top
//
// Pins: btle_mvp_pico2ice.pcf.  Build: build.ps1 (yosys -DICE40, nextpnr-ice40 --up5k sg48).
//
// The AT86RF215 runs in I/Q radio mode (RF_IQIFC1.CHPM = 1) with the 1.2 V LVDS common mode
// (RF_IQIFC0.CMV1V2 = 1) needed by the SN65LVDS049.  rf215_init writes those over SPI after every
// reset; nothing has to be configured from the RP2350.  The RP2350 must only supply clk_local
// (12 MHz on ICE_35_G0, which firmware/radio_cli does in fpga_init()).
//
// This wrapper only fixes the board-level choices:
//   * rst_ext is tied low (the design has its own power-on reset).
//   * dbg_rf_irq is left unconnected on a pin (it is readable over the debug SPI port).
//   * Radio SPI on the RP-ICE PMOD pins: SCK ICE18, MOSI ICE23, MISO ICE19, SELN ICE25.
//   * Debug SPI slave for the RP2350 on the other RP-ICE pins (GPIO26 SCK -> ICE21,
//     GPIO20 MOSI -> ICE27, GPIO24 MISO <- ICE26, GPIO22 CS -> ICE20).  The loader firmware's
//     terminal uses it to read status and radio registers through the FPGA.

module btle_mvp_pico2ice (
    input  wire clk_local,

    output wire rf_rstn,
    output wire rf_seln,
    output wire rf_sclk,
    output wire rf_mosi,
    input  wire rf_miso,
    input  wire rf_irq,

    input  wire rxclk_in,
    input  wire rxd_in,
    output wire txd_out,
    output wire txclk_out,

    output wire uart_txd,
    output wire led_ready,
    output wire led_fault,
    output wire led_rx_ok,
    output wire led_tx,
    output wire dbg_rx_lock,

    input  wire dbg_sck,
    input  wire dbg_csn,
    input  wire dbg_mosi,
    output wire dbg_miso
);

    btle_mvp_top u_top (
        .clk_local(clk_local),
        .rst_ext(1'b0),
        .rf_rstn(rf_rstn), .rf_seln(rf_seln), .rf_sclk(rf_sclk), .rf_mosi(rf_mosi),
        .rf_miso(rf_miso), .rf_irq(rf_irq),
        .rxclk_in(rxclk_in), .rxd_in(rxd_in), .txd_out(txd_out), .txclk_out(txclk_out),
        .uart_txd(uart_txd),
        .led_ready(led_ready), .led_fault(led_fault), .led_rx_ok(led_rx_ok), .led_tx(led_tx),
        .dbg_rx_lock(dbg_rx_lock), .dbg_rf_irq(),
        .dbg_sck(dbg_sck), .dbg_csn(dbg_csn), .dbg_mosi(dbg_mosi), .dbg_miso(dbg_miso)
    );

endmodule
