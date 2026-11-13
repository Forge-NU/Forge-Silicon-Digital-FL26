// sync_cells.v  --  small clock-domain-crossing cells used by btle_mvp_top
//
//   rst_sync   : reset asserted asynchronously, released synchronously, so a domain whose
//                clock is not running yet (RXCLK exists only in TXPREP, TX and RX) still
//                starts in reset.
//   sync_2ff   : two-flop synchroniser for a slowly changing level.
//   pulse2tog  : turns a one-clock pulse in the source domain into a toggle.
//   tog2pulse  : turns that toggle into a one-clock pulse in the destination domain.
//                Use pulse2tog -> tog2pulse for any single-event signal, as long as events
//                are further apart than about three destination clocks.
//   pulse_stretch : holds a short pulse high long enough to see on an LED.
// NOT SIMULATED OR SYNTHESISED when written.

module rst_sync (
    input  wire clk,
    input  wire rst_in,       // asynchronous, active high
    output wire rst_out       // synchronous to clk
);
    reg [1:0] r;
    always @(posedge clk or posedge rst_in) begin
        if (rst_in) r <= 2'b11;
        else        r <= {r[0], 1'b0};
    end
    assign rst_out = r[1];
endmodule


module sync_2ff #(parameter W = 1) (
    input  wire         clk,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
    reg [W-1:0] a, b;
    always @(posedge clk) begin
        a <= d;
        b <= a;
    end
    assign q = b;
endmodule


module pulse2tog (
    input  wire clk,
    input  wire rst,
    input  wire pulse,
    output reg  tog
);
    always @(posedge clk) begin
        if (rst)        tog <= 1'b0;
        else if (pulse) tog <= ~tog;
    end
endmodule


module tog2pulse (
    input  wire clk,
    input  wire rst,
    input  wire tog,
    output wire pulse
);
    reg a, b, c;
    always @(posedge clk) begin
        if (rst) begin
            // start from the current level so a toggle that happened while this domain was
            // in reset does not turn into a false pulse
            a <= tog;
            b <= tog;
            c <= tog;
        end else begin
            a <= tog;
            b <= a;
            c <= b;
        end
    end
    assign pulse = b ^ c;
endmodule


module pulse_stretch #(parameter integer CLKS = 1200000) (
    input  wire clk,
    input  wire rst,
    input  wire pulse,
    output wire out
);
    reg [31:0] cnt;
    always @(posedge clk) begin
        if (rst)        cnt <= 32'd0;
        else if (pulse) cnt <= CLKS;
        else if (cnt != 0) cnt <= cnt - 32'd1;
    end
    assign out = (cnt != 0);
endmodule
