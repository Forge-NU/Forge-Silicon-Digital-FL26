// dbg_port_tb.v  --  RP2350 debug SPI -> spi_dbg_slave -> register map -> rf215_init -> radio model
//
//   iverilog -g2005 -I. -o dbg_port_tb dbg_port_tb.v btle_mvp_pico2ice.v btle_mvp_top.v rf215_init.v
//       spi_master.v spi_dbg_slave.v rf215_model.v bb_clkgen.v ddr_io.v lvds_rx.v lvds_tx.v
//       btle_tx_min.v msk_modulator.v pdu_uart_dump.v sync_cells.v btle_rx_sps.v
//       ../BTLE/verilog/{btle_rx_core,gfsk_demodulation,search_unique_bit_sequence,scramble_core,
//       crc24_core,serial_in_ram_out,sdpram_two_clk}.v
//   vvp dbg_port_tb
//
// The full board top runs with the real config (12 MHz clk_local, 2 MHz radio SPI); no RXCLK.
// A 1 MHz mode-0 master (the RP2350's SPI1) reads the status registers and uses the
// read-through to fetch RF_PN (0x000D) and RF24_STATE (0x0202) from the radio model.

`timescale 1ns/1ps

module dbg_port_tb;
    reg clk = 1'b0;
    always #41.667 clk = ~clk;               // 12 MHz

    wire rf_rstn, rf_seln, rf_sclk, rf_mosi, rf_miso;
    wire [7:0] radio_state;
    reg  sck = 1'b0, csn = 1'b1, mosi = 1'b0;
    wire miso;

    btle_mvp_pico2ice dut (
        .clk_local(clk),
        .rf_rstn(rf_rstn), .rf_seln(rf_seln), .rf_sclk(rf_sclk), .rf_mosi(rf_mosi),
        .rf_miso(rf_miso), .rf_irq(1'b0),
        .rxclk_in(1'b0), .rxd_in(1'b1), .txd_out(), .txclk_out(),
        .uart_txd(), .led_ready(), .led_fault(), .led_rx_ok(), .led_tx(), .dbg_rx_lock(),
        .dbg_sck(sck), .dbg_csn(csn), .dbg_mosi(mosi), .dbg_miso(miso)
    );

    rf215_model #(.PN(8'h34)) radio (
        .rstn(rf_rstn), .seln(rf_seln), .sclk(rf_sclk), .mosi(rf_mosi), .miso(rf_miso),
        .state_reg(radio_state), .illegal()
    );

    localparam real HALF = 500.0;            // 1 MHz SPI
    function [7:0] dummy; input x; dummy = 8'h00; endfunction

    reg [7:0] rx;
    task xfer;                               // one byte, mode 0, MSB first
        input  [7:0] tx;
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                mosi = tx[k];
                #(HALF) sck = 1'b1;
                rx[k] = miso;
                #(HALF) sck = 1'b0;
            end
        end
    endtask

    reg [7:0] marker;
    reg [7:0] rbuf [0:15];
    task rd_regs;                            // read n registers starting at a
        input [6:0] a;
        input integer n;
        integer i;
        begin
            csn = 1'b0; #(HALF);
            xfer({1'b0, a}); marker = rx;
            for (i = 0; i < n; i = i + 1) begin xfer(8'h00); rbuf[i] = rx; end
            #(HALF) csn = 1'b1; #(4 * HALF);
        end
    endtask
    task wr_reg;
        input [6:0] a;
        input [7:0] v;
        begin
            csn = 1'b0; #(HALF);
            xfer({1'b1, a}); xfer(v);
            #(HALF) csn = 1'b1; #(4 * HALF);
        end
    endtask

    reg [7:0] radio_val;
    integer tries;
    task radio_rd;                           // read-through
        input [13:0] ra;
        begin
            wr_reg(7'h10, {2'b00, ra[13:8]});
            wr_reg(7'h11, ra[7:0]);
            wr_reg(7'h12, 8'h01);
            tries = 0;
            rd_regs(7'h12, 1);
            while (rbuf[0][1] && tries < 200) begin #(5000); rd_regs(7'h12, 1); tries = tries + 1; end
            rd_regs(7'h13, 1);
            radio_val = rbuf[0];
        end
    endtask

    integer errors = 0;
    task check;
        input cond;
        input [255:0] msg;
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL: %0s at %0t", msg, $time); end
        end
    endtask

    initial begin
        #(12_000_000);                       // POR (5.5 ms) + radio bring-up
        rd_regs(7'h00, 11);
        $display("marker %02X  regs: magic %02X ver %02X status %02X PN %02X last %02X pc %0d state %0d faults %0d",
                 marker, rbuf[0], rbuf[1], rbuf[2], rbuf[3], rbuf[4], rbuf[5], rbuf[6], rbuf[7]);
        check(marker  == 8'hA5, "no A5 link marker");
        check(rbuf[0] == 8'hB7, "magic wrong");
        check(rbuf[1] == 8'h01, "version wrong");
        check(rbuf[2][0] == 1'b1 && rbuf[2][1] == 1'b0, "status: not ready or faulted");
        check(rbuf[3] == 8'h34, "bring-up part number wrong");
        check(rbuf[7] == 8'h00, "fault count not zero");

        radio_rd(14'h000D);
        $display("radio RF_PN via FPGA = %02X (%0d polls)", radio_val, tries);
        check(radio_val == 8'h34, "read-through RF_PN wrong");
        radio_rd(14'h0202);
        $display("radio RF24_STATE via FPGA = %02X", radio_val);
        check(radio_val == 8'h05, "read-through RF24_STATE not RX");
        radio_rd(14'h000B);
        $display("radio RF_IQIFC1 via FPGA = %02X", radio_val);
        check(radio_val == 8'h12, "read-through IQIFC1 not CHPM=1/SKEWDRV=2");

        if (errors == 0) $display("PASS: debug SPI port and radio read-through");
        else             $display("FAILED: %0d error(s)", errors);
        $finish;
    end
endmodule
