// pdu_uart_dump.v  --  print each decoded packet as hex text on a UART
//
// On `evt` (one clock, local domain) with a good CRC it sends
//        RX: 42 0F 01 00 00 EE FF C0 02 01 06 05 09 42 54 4C 45 <CR><LF>
// that is the 2-byte PDU header plus the payload, read from btle_rx's result RAM.  With
// DUMP_BAD_CRC it also prints failures, prefixed "BAD: ".  Events that arrive while a dump is
// in progress are ignored, and the RAM is overwritten by the next received packet, so a dump
// that overlaps a new packet can show mixed data.  Fine for bring-up.
//
// 8N1, LSB first.  NOT SIMULATED OR SYNTHESISED when written.

module uart_tx #(
    parameter integer CLK_HZ = 12000000,
    parameter integer BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       valid,
    input  wire [7:0] data,
    output wire       ready,
    output wire       txd
);
    localparam integer DIV = (CLK_HZ / BAUD) < 2 ? 2 : (CLK_HZ / BAUD);

    reg [15:0] cnt;
    reg [3:0]  bitn;
    reg [9:0]  sh;
    reg        busy;

    assign ready = !busy;
    assign txd   = busy ? sh[0] : 1'b1;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            cnt  <= 16'd0;
            bitn <= 4'd0;
            sh   <= 10'h3FF;
        end else if (!busy) begin
            if (valid) begin
                sh   <= {1'b1, data, 1'b0};      // stop, data[7:0], start
                busy <= 1'b1;
                cnt  <= DIV - 1;
                bitn <= 4'd0;
            end
        end else begin
            if (cnt == 16'd0) begin
                cnt  <= DIV - 1;
                sh   <= {1'b1, sh[9:1]};
                bitn <= bitn + 4'd1;
                if (bitn == 4'd9) busy <= 1'b0;
            end else begin
                cnt <= cnt - 16'd1;
            end
        end
    end
endmodule


module pdu_uart_dump #(
    parameter integer CLK_HZ        = 12000000,
    parameter integer BAUD          = 115200,
    // Clocks to wait after changing ram_addr before ram_data is valid.  UNCHECKED: the
    // result RAM has a registered read (1 clock) and btle_rx adds a mux; 4 is generous.
    // Raise it if the printed bytes look shifted or repeated.
    parameter integer RAM_READ_WAIT = 4,
    parameter         DUMP_BAD_CRC  = 0,
    parameter integer MAX_BYTES     = 64         // at most 255
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       evt,         // a packet was decoded
    input  wire [7:0] len,         // payload length from the header, bytes after the 2-byte header
    input  wire       crc_ok,
    output reg  [8:0] ram_addr,
    input  wire [7:0] ram_data,
    output wire       txd,
    output wire       busy
);
    localparam [3:0] S_IDLE  = 4'd0,
                     S_HDR   = 4'd1,
                     S_FETCH = 4'd2,
                     S_HI    = 4'd3,
                     S_LO    = 4'd4,
                     S_SP    = 4'd5,
                     S_CR    = 4'd6,
                     S_LF    = 4'd7;

    reg [3:0] st;
    reg [2:0] hi;
    reg       ok_r;
    reg [7:0] nbytes;
    reg [7:0] k;
    reg [7:0] bytev;
    reg [7:0] wcnt;

    function [7:0] hexc;
        input [3:0] v;
        begin
            hexc = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h41 + {4'd0, v} - 8'd10);
        end
    endfunction

    function [7:0] hdr_char;
        input [2:0] idx;
        input       ok;
        begin
            if (ok) begin
                case (idx)
                    3'd0: hdr_char = "R";
                    3'd1: hdr_char = "X";
                    3'd2: hdr_char = ":";
                    3'd3: hdr_char = " ";
                    default: hdr_char = 8'h00;
                endcase
            end else begin
                case (idx)
                    3'd0: hdr_char = "B";
                    3'd1: hdr_char = "A";
                    3'd2: hdr_char = "D";
                    3'd3: hdr_char = ":";
                    3'd4: hdr_char = " ";
                    default: hdr_char = 8'h00;
                endcase
            end
        end
    endfunction

    wire [7:0] hdr_c = hdr_char(hi, ok_r);
    wire [8:0] want  = {1'b0, len} + 9'd2;

    reg [7:0] ch;
    reg       ch_v;
    always @* begin
        ch   = 8'h00;
        ch_v = 1'b0;
        case (st)
            S_HDR: begin ch = hdr_c;            ch_v = (hdr_c != 8'h00); end
            S_HI:  begin ch = hexc(bytev[7:4]); ch_v = 1'b1; end
            S_LO:  begin ch = hexc(bytev[3:0]); ch_v = 1'b1; end
            S_SP:  begin ch = " ";              ch_v = 1'b1; end
            S_CR:  begin ch = 8'h0D;            ch_v = 1'b1; end
            S_LF:  begin ch = 8'h0A;            ch_v = 1'b1; end
            default: ;
        endcase
    end

    wire u_ready;
    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart (
        .clk(clk), .rst(rst), .valid(ch_v), .data(ch), .ready(u_ready), .txd(txd)
    );
    wire xfer = ch_v && u_ready;

    assign busy = (st != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            st       <= S_IDLE;
            hi       <= 3'd0;
            ok_r     <= 1'b0;
            nbytes   <= 8'd0;
            k        <= 8'd0;
            bytev    <= 8'd0;
            wcnt     <= 8'd0;
            ram_addr <= 9'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (evt && (crc_ok || DUMP_BAD_CRC)) begin
                        ok_r   <= crc_ok;
                        nbytes <= (want > MAX_BYTES) ? MAX_BYTES[7:0] : want[7:0];
                        k      <= 8'd0;
                        hi     <= 3'd0;
                        st     <= S_HDR;
                    end
                end
                S_HDR: begin
                    if (hdr_c == 8'h00) begin
                        ram_addr <= 9'd0;
                        wcnt     <= 8'd0;
                        st       <= S_FETCH;
                    end else if (xfer) begin
                        hi <= hi + 3'd1;
                    end
                end
                S_FETCH: begin
                    if (wcnt >= RAM_READ_WAIT) begin
                        bytev <= ram_data;
                        st    <= S_HI;
                    end else begin
                        wcnt <= wcnt + 8'd1;
                    end
                end
                S_HI: if (xfer) st <= S_LO;
                S_LO: if (xfer) st <= S_SP;
                S_SP: begin
                    if (xfer) begin
                        if (k + 8'd1 >= nbytes) begin
                            st <= S_CR;
                        end else begin
                            k        <= k + 8'd1;
                            ram_addr <= {1'b0, k} + 9'd1;
                            wcnt     <= 8'd0;
                            st       <= S_FETCH;
                        end
                    end
                end
                S_CR: if (xfer) st <= S_LF;
                S_LF: if (xfer) st <= S_IDLE;
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
