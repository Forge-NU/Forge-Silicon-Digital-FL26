// rf215_model.v
//
// Behavioural stand-in for the AT86RF215 SPI interface, for simulation only.
// Models just enough to exercise rf215_init: part number, a register array,
// the RFn_STATE / RFn_CMD behaviour, and the IQIFC2 SYNC bit.
// NOT a model of the real device's timing or analog behaviour.
//
// STUCK = 1 makes CMD writes have no effect (tests the poll timeout).
// `illegal` goes high if TX or RX is commanded from anywhere but TXPREP.

`timescale 1ns/1ps

module rf215_model #(
    parameter [7:0] PN    = 8'h34,   // 0x34 AT86RF215, 0x35 IQ, 0x36 M (no 2.4 GHz radio)
    parameter       STUCK = 0
)(
    input  wire       rstn,
    input  wire       seln,
    input  wire       sclk,
    input  wire       mosi,
    output reg        miso,
    output reg  [7:0] state_reg,
    output reg        illegal
);

    reg [7:0]  mem [0:1023];
    reg [7:0]  cmd_log [0:255];
    integer    cmd_n;
    integer    i;

    reg [4:0]  bitcnt;
    reg [23:0] shin;
    reg        is_wr;
    reg [13:0] addr;
    reg [7:0]  rdata;

    initial begin
        miso      = 1'b0;
        illegal   = 1'b0;
        state_reg = 8'h07;               // RESET
        cmd_n     = 0;
        bitcnt    = 5'd0;
        shin      = 24'd0;
        is_wr     = 1'b0;
        addr      = 14'd0;
        rdata     = 8'd0;
        for (i = 0; i < 1024; i = i + 1) mem[i] = 8'h00;
    end

    // hardware reset: registers cleared, state becomes TRXOFF shortly after release
    always @(negedge rstn) begin
        state_reg = 8'h07;
        for (i = 0; i < 1024; i = i + 1) mem[i] = 8'h00;
    end
    always @(posedge rstn) begin
        #2000;
        state_reg = 8'h02;               // TRXOFF
    end

    function [7:0] rd;
        input [13:0] a;
        reg   [7:0]  iqifc1;
        begin
            iqifc1 = mem[11];                                   // IQIFC1 at 0x000B
            if      (a == 14'h000D) rd = PN;
            else if (a == 14'h0202) rd = state_reg;
            else if (a == 14'h000C) rd = (iqifc1[6:4] == 3'd1) ? 8'h80 : 8'h00; // SYNC once CHPM=1
            else                    rd = mem[a[9:0]];
        end
    endfunction

    task do_write;
        input [13:0] a;
        input [7:0]  v;
        begin
            mem[a[9:0]] = v;
            if (a == 14'h0203) begin
                cmd_log[cmd_n] = v;
                cmd_n = cmd_n + 1;
                if (!STUCK) begin
                    case (v[2:0])
                        3'd2: state_reg = 8'h02;
                        3'd3: state_reg = 8'h03;
                        3'd4: begin
                            if (state_reg[2:0] != 3'd3) illegal = 1'b1;
                            state_reg = 8'h04;
                        end
                        3'd5: begin
                            if (state_reg[2:0] != 3'd3) illegal = 1'b1;
                            state_reg = 8'h05;
                        end
                        default: ;
                    endcase
                end
            end
        end
    endtask

    always @(negedge seln) begin
        bitcnt = 5'd0;
        shin   = 24'd0;
    end

    always @(posedge sclk) begin
        if (!seln) begin
            shin   = {shin[22:0], mosi};
            bitcnt = bitcnt + 5'd1;
            if (bitcnt == 5'd16) begin
                is_wr = (shin[15:14] == 2'b10);
                addr  = shin[13:0];
                rdata = rd(shin[13:0]);
            end
            if (bitcnt == 5'd24 && is_wr) begin
                do_write(addr, shin[7:0]);
            end
        end
    end

    // read data is presented on falling edges so the master samples it on rising edges
    always @(negedge sclk) begin
        if (!seln && bitcnt >= 5'd16 && bitcnt < 5'd24 && !is_wr)
            miso = rdata[23 - bitcnt];
        else
            miso = 1'b0;
    end

endmodule
