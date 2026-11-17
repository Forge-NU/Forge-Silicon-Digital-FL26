`timescale 1ns/100fs
`default_nettype none

// Behavioral test of iq_lvds_test with a crude model of the radio's loopback:
// RXD = TXD delayed by DELAY_BITS bit-times (+ ~3.9 ns so the clock edge lands
// mid-eye, like the radio's default SKEWDRV=2).
//
//   iverilog -g2012 -DSIM -PDELAY_BITS=7 -o tb tb_iq_lvds_test.v iq_lvds_test.v && vvp tb
//   add -DSIM_SWAP to force the other in-pair bit order

module tb;
    parameter DELAY_BITS = 7;

    reg rx_clk = 1'b0;
    always #7.8125 rx_clk = ~rx_clk;          // 64 MHz

    wire tx_data, tx_clk;
    reg  rx_data = 1'b0;
    always @(tx_data) rx_data <= #(DELAY_BITS*7.8125 + 3.90625) tx_data;

    wire led_clk, led_lock, led_ok, led_err;

    iq_lvds_test dut (
        .rx_clk_pin(rx_clk), .rx_data_pin(rx_data),
        .tx_clk_pin(tx_clk), .tx_data_pin(tx_data),
        .led_clk(led_clk), .led_lock(led_lock), .led_ok(led_ok), .led_err(led_err)
    );

    integer err_events = 0;
    real    t_lock = -1, t_ok = -1;
    always @(posedge led_err) err_events = err_events + 1;
    always @(posedge led_lock) if (t_lock < 0) t_lock = $realtime;
    always @(posedge led_ok)   if (t_ok   < 0) t_ok   = $realtime;

    initial begin
        #600000;   // 600 us
        $display("DELAY_BITS=%0d  lock@%0.1f us  ok@%0.1f us  err_events=%0d  final: lock=%b ok=%b",
                 DELAY_BITS, t_lock/1000.0, t_ok/1000.0, err_events, led_lock, led_ok);
        if (led_lock && led_ok && err_events == 0) $display("PASS");
        else                                       $display("FAIL");
        $finish;
    end
endmodule
