// rf215_init_tb.v
//
// Run with Icarus Verilog:
//   iverilog -g2005 -o tb spi_master.v rf215_init.v rf215_model.v rf215_init_tb.v
//   vvp tb                                   # scenario 0: normal boot and TX/RX loop
//   iverilog -g2005 -P rf215_init_tb.SCENARIO=1 -o tb1 spi_master.v rf215_init.v rf215_model.v rf215_init_tb.v && vvp tb1
//   iverilog -g2005 -P rf215_init_tb.SCENARIO=2 -o tb2 spi_master.v rf215_init.v rf215_model.v rf215_init_tb.v && vvp tb2
//
// SCENARIO 0: boot, configure, loop.  Checks register contents, the command
//             sequence TXPREP,RX then (TXPREP,TX,TXPREP,RX) repeating, that the
//             I/Q stream is enabled only while the radio is in TXPREP or TX, and
//             that every burst starts and stops the stream once.
// SCENARIO 1: radio reports part number 0x36 (sub-GHz only, no 2.4 GHz radio);
//             expects fault, never ready.
// SCENARIO 2: radio ignores CMD writes; expects poll timeout, fault, never ready.
//
// NOT RUN when written.  Timing parameters are shortened for simulation.

`timescale 1ns/1ps

module rf215_init_tb;
    parameter SCENARIO = 0;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #31.25 clk = ~clk;              // 16 MHz

    wire rstn, seln, sclk, mosi, miso;
    wire tx_go, stream_en, ready, fault, listening;
    reg  tx_data_done = 1'b0;
    reg  tx_done      = 1'b0;
    wire [7:0] radio_state;
    wire       illegal;

    rf215_init #(
        .RST_LOW_CLKS(20),
        .BOOT_CLKS(200),
        .POLL_MAX(20),
        .POLL_GAP_CLKS(4),
        .TX_PERIOD_CLKS(3000),
        .TX_TIMEOUT_CLKS(4000),
        .SYNC_CLKS(40),
        .LEAD_CLKS(20),
        .FAULT_CLKS(500)
    ) dut (
        .clk(clk), .rst(rst),
        .rstn_radio(rstn), .seln(seln), .sclk(sclk), .mosi(mosi), .miso(miso),
        .stream_en(stream_en), .tx_go(tx_go),
        .tx_data_done(tx_data_done), .tx_done(tx_done),
        .ready(ready), .fault(fault), .listening(listening)
    );

    rf215_model #(
        .PN(SCENARIO == 1 ? 8'h36 : 8'h34),
        .STUCK(SCENARIO == 2)
    ) radio (
        .rstn(rstn), .seln(seln), .sclk(sclk), .mosi(mosi), .miso(miso),
        .state_reg(radio_state), .illegal(illegal)
    );

    integer tx_go_count        = 0;
    integer stream_on_count    = 0;
    integer stream_violations  = 0;
    integer fault_seen         = 0;
    integer ready_seen         = 0;
    reg     stream_prev        = 1'b0;

    always @(posedge clk) begin
        if (tx_go) tx_go_count = tx_go_count + 1;
        if (fault) fault_seen  = 1;
        if (ready) ready_seen  = 1;
        if (stream_en && !stream_prev) stream_on_count = stream_on_count + 1;
        stream_prev = stream_en;
        // the radio's TX link is only enabled in TXPREP and TX
        if (stream_en && radio_state[2:0] != 3'd3 && radio_state[2:0] != 3'd4)
            stream_violations = stream_violations + 1;
    end

    // stand-in for the TX datapath: packet samples take 800 clks (50 us),
    // then padding takes 400 clks (25 us)
    always @(posedge clk) begin
        if (tx_go) begin
            repeat (800) @(posedge clk);
            tx_data_done <= 1'b1;
            @(posedge clk);
            tx_data_done <= 1'b0;
            repeat (400) @(posedge clk);
            tx_done <= 1'b1;
            @(posedge clk);
            tx_done <= 1'b0;
        end
    end

    integer errors = 0;
    task check;
        input cond;
        input [255:0] msg;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    initial begin
        $dumpfile("rf215_init_tb.vcd");
        $dumpvars(0, rf215_init_tb);

        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (80000) @(posedge clk);

        case (SCENARIO)
            0: begin
                check(ready_seen == 1,            "ready never asserted");
                check(fault_seen == 0,            "unexpected fault");
                check(illegal == 1'b0,            "illegal state transition commanded");
                check(tx_go_count >= 2,           "fewer than two TX bursts");
                check(stream_on_count >= tx_go_count, "stream not started for every burst");
                check(stream_violations == 0,     "stream enabled outside TXPREP/TX");
                check(radio.mem[10]  == 8'h36,    "IQIFC0 wrong");
                check(radio.mem[11]  == 8'h12,    "IQIFC1 not CHPM=1 with SKEWDRV 2");
                check(radio.mem[517] == 8'hF0,    "CCF0L wrong");
                check(radio.mem[518] == 8'h8C,    "CCF0H wrong");
                check(radio.mem[520] == 8'h00,    "CNM wrong");
                check(radio.mem[522] == 8'h61,    "RXDFE wrong");
                check(radio.mem[531] == 8'h81,    "TXDFE wrong");
                check(radio.mem[532] == 8'h71,    "PAC wrong");
                check(radio.cmd_log[0] == 8'h03,  "cmd 0 should be TXPREP");
                check(radio.cmd_log[1] == 8'h05,  "cmd 1 should be RX");
                check(radio.cmd_log[2] == 8'h03,  "cmd 2 should be TXPREP");
                check(radio.cmd_log[3] == 8'h04,  "cmd 3 should be TX");
                check(radio.cmd_log[4] == 8'h03,  "cmd 4 should be TXPREP");
                check(radio.cmd_log[5] == 8'h05,  "cmd 5 should be RX");
            end
            1: begin
                check(fault_seen == 1,            "part number 0x36 did not raise fault");
                check(ready_seen == 0,            "ready asserted with a sub-GHz-only part");
            end
            2: begin
                check(fault_seen == 1,            "stuck radio did not raise fault");
                check(ready_seen == 0,            "ready asserted with a stuck radio");
            end
        endcase

        if (errors == 0) $display("PASS (scenario %0d)", SCENARIO);
        else             $display("FAILED: %0d error(s) (scenario %0d)", errors, SCENARIO);
        $finish;
    end
endmodule
