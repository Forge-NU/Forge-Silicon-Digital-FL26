`timescale 1ns/1ps
// tb_bit_timer — self-checking testbench for bit_timer
//
// Rules checked every clock:
//   - step fires exactly every div clocks (first one div clocks after enable)
//   - comp_strobe fires exactly strobe_at + 1 clocks after each step
//   - exactly one comp_strobe per step
//   - no outputs while disabled or in reset
//   - the right number of steps for each run
//
// The monitor tracks enable AND reset as the DUT saw them at the last
// clock edge (en_q / rst_q), so its cycle count lines up with the DUT's
// counter after both a re-enable and a reset release.
module tb_bit_timer;
    logic       clk = 0, rst_n = 0, enable = 0;
    logic [7:0] div = 8'd12, strobe_at = 8'd8;
    logic       step, comp_strobe;

    always #41.667 clk = ~clk;  // ~12 MHz

    bit_timer dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .div(div), .strobe_at(strobe_at),
        .step(step), .comp_strobe(comp_strobe)
    );

    // ------------------------------------------------------------------
    // Bookkeeping
    // ------------------------------------------------------------------
    int errors = 0, checks = 0;
    int since = 0;        // clocks since the last step (or since enable / reset release)
    int strobes = 0;      // strobes seen since the last step
    int steps_seen = 0;   // total steps seen
    logic en_q  = 0;      // the enable value the DUT saw at the last clock edge
    logic rst_q = 0;      // 1 if the DUT was out of reset at the last clock edge

    always @(posedge clk) en_q <= enable;

    // Mirrors the DUT's async reset: asserts immediately, releases at the
    // first clock edge after rst_n goes high (when the DUT starts counting).
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rst_q <= 1'b0;
        else        rst_q <= 1'b1;

    task automatic check(input bit cond, input string msg);
        checks++;
        if (!cond) begin
            errors++;
            $display("FAIL @ %t: %s (div=%0d, strobe_at=%0d, since=%0d)",
                     $realtime, msg, div, strobe_at, since);
        end
    endtask

    // ------------------------------------------------------------------
    // Monitor: look at the outputs in the middle of every clock cycle
    // ------------------------------------------------------------------
    always @(negedge clk) begin
        if (!rst_q || !en_q) begin
            check(!step && !comp_strobe, "output active while disabled or in reset");
            since   = 0;
            strobes = 0;
        end else begin
            since++;
            if (comp_strobe) begin
                strobes++;
                check(since == strobe_at + 1, "comp_strobe at the wrong time");
            end
            if (step) begin
                steps_seen++;
                check(since == div,  "step period is wrong");
                check(strobes == 1,  "not exactly one comp_strobe in this step");
                since   = 0;
                strobes = 0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Run the timer with one div / strobe_at setting for some steps
    // ------------------------------------------------------------------
    task automatic run_config(input logic [7:0] d, input logic [7:0] s, input int periods);
        int start_steps;
        @(posedge clk) #1;
        div         = d;          // only change settings while disabled
        strobe_at   = s;
        start_steps = steps_seen;
        enable      = 1;
        repeat (periods * d) @(posedge clk);
        #1 enable = 0;
        @(negedge clk) #1;
        check(steps_seen - start_steps == periods, "wrong number of steps in run");
        repeat (3) @(posedge clk);
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    initial begin
        int start_steps;
        $timeformat(-9, 3, " ns", 0);   // %t prints in ns with 3 decimals
        $dumpfile("dump.vcd");
        $dumpvars;

        // 1. Reset, then sit disabled: nothing should fire
        repeat (3) @(posedge clk);
        #1 rst_n = 1;
        repeat (10) @(posedge clk);

        // 2. Different speeds and strobe positions
        run_config(8'd12,  8'd8,   5);  // normal setting
        run_config(8'd2,   8'd0,   8);  // fastest legal setting
        run_config(8'd3,   8'd1,   6);
        run_config(8'd12,  8'd10,  5);  // latest legal strobe (div - 2)
        run_config(8'd20,  8'd0,   4);  // earliest strobe
        run_config(8'd255, 8'd100, 2);  // slowest setting

        // 3. Disable in the middle of a step, then re-enable: should restart cleanly
        @(posedge clk) #1;
        div = 8'd12; strobe_at = 8'd8; enable = 1;
        repeat (12 + 5) @(posedge clk);
        #1 enable = 0;
        repeat (4) @(posedge clk);
        #1 enable = 1;
        start_steps = steps_seen;
        repeat (24) @(posedge clk);
        #1 enable = 0;
        @(negedge clk) #1;
        check(steps_seen - start_steps == 2, "wrong step count after re-enable");
        repeat (3) @(posedge clk);

        // 4. Reset in the middle of a step: should clear and restart cleanly
        @(posedge clk) #1;
        enable = 1;
        repeat (7) @(posedge clk);
        #1 rst_n = 0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1;
        start_steps = steps_seen;
        repeat (24) @(posedge clk);
        #1 enable = 0;
        @(negedge clk) #1;
        check(steps_seen - start_steps == 2, "wrong step count after reset");

        // Summary
        $display("--------------------------------------------");
        if (errors == 0)
            $display("ALL TESTS PASSED (%0d checks, %0d steps)", checks, steps_seen);
        else
            $display("%0d FAILURES out of %0d checks", errors, checks);
        $display("--------------------------------------------");
        $finish;
    end
endmodule
