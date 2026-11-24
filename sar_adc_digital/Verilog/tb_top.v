`timescale 1ns/1ps
// tb_top — self-checking integration testbench for sar_adc_digital
//          (bit_timer + sar_fsm)
//
// Models:
//   - sample-and-hold: the input is frozen when sample falls
//   - latched comparator: decides (vin_held >= dac_code) only on comp_strobe,
//     and its output goes to X once the FSM has consumed it on step. If the
//     FSM ever reads the comparator without a fresh strobe, X ends up in the
//     result and the result check fails.
//
// Rules checked:
//   - every conversion's result equals the held input
//   - sample window lasts SAMPLE_CYCLES*div + 1 clocks
//   - conversion (sample rising -> eoc) lasts (SAMPLE_CYCLES+N)*div + 2 clocks
//   - free-run: eoc pulses are (SAMPLE_CYCLES+N)*div + 3 clocks apart
//   - eoc is a single-clock pulse; result only changes with eoc
//   - nothing fires while idle; everything clears in reset
//   - a reset in the middle of a conversion recovers cleanly
module tb_top;
    localparam N   = 12;
    localparam SC  = 2;            // SAMPLE_CYCLES
    localparam MAX = (1 << N) - 1;

    reg           clk = 0, rst_n = 0, start = 0;
    reg   [7:0]   div = 8'd12, strobe_at = 8'd8;
    reg           comp_out;            // starts as X until the first strobe
    wire          sample, comp_strobe, eoc;
    wire  [N-1:0] dac_code, result;

    always #41.667 clk = ~clk;  // ~12 MHz

    sar_adc_digital #(.N(N), .SAMPLE_CYCLES(SC)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .comp_out(comp_out),
        .div(div), .strobe_at(strobe_at),
        .sample(sample), .comp_strobe(comp_strobe),
        .dac_code(dac_code), .result(result), .eoc(eoc)
    );

    // ------------------------------------------------------------------
    // Analog models
    // ------------------------------------------------------------------
    reg [N-1:0] vin = 0;               // input "voltage" as a code
    reg [N-1:0] vin_held;              // what the sample-and-hold captured

    always @(negedge sample) vin_held = vin;

    // The DUT's step pulse, needed to model the comparator resetting after
    // its decision has been used.
    wire step = dut.step;

    always @(posedge clk) begin
        if (comp_strobe) comp_out <= (vin_held >= dac_code);  // 1 = Vin >= Vdac
        else if (step)   comp_out <= 1'bx;                    // decision consumed
    end

    // ------------------------------------------------------------------
    // Bookkeeping
    // ------------------------------------------------------------------
    integer errors = 0, checks = 0, conversions = 0, sample_strobes = 0;
    integer cyc = 0;                   // clock edge counter
    integer start_cyc = 0;             // cyc when the current conversion began
    integer prev_eoc_cyc = -1;
    reg     idle_window  = 0;          // stimulus says the DUT should be idle
    reg     free_running = 0;
    reg           sample_d = 0, eoc_d = 0, rst_n_d = 0;
    reg   [N-1:0] result_d;
    reg   [8*64-1:0] msg;              // message buffer (Verilog has no string type)
    integer k;

    always @(posedge clk) cyc = cyc + 1;

    task automatic check(input cond, input [8*64-1:0] m);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL @ %t: %0s (div=%0d, strobe_at=%0d)",
                         $realtime, m, div, strobe_at);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Monitor: look at the outputs in the middle of every clock cycle
    // ------------------------------------------------------------------
    always @(negedge clk) begin
        if (!rst_n) begin
            check(!sample && !comp_strobe && !eoc && result == 0 && dac_code == 0,
                  "outputs not cleared during reset");
        end else begin
            if (sample && !sample_d)
                start_cyc = cyc;

            if (!sample && sample_d) begin
                $sformat(msg, "sample window was %0d clocks, expected %0d",
                         cyc - start_cyc, SC * div + 1);
                check(cyc - start_cyc == SC * div + 1, msg);
            end

            if (sample && comp_strobe)
                sample_strobes = sample_strobes + 1;

            if (eoc && !eoc_d) begin
                conversions = conversions + 1;
                $sformat(msg, "result = %0d, expected %0d", result, vin_held);
                check(result === vin_held, msg);
                $sformat(msg, "conversion took %0d clocks, expected %0d",
                         cyc - start_cyc, (SC + N) * div + 2);
                check(cyc - start_cyc == (SC + N) * div + 2, msg);
                if (free_running && prev_eoc_cyc >= 0) begin
                    $sformat(msg, "eoc spacing was %0d clocks, expected %0d",
                             cyc - prev_eoc_cyc, (SC + N) * div + 3);
                    check(cyc - prev_eoc_cyc == (SC + N) * div + 3, msg);
                end
                prev_eoc_cyc = cyc;
            end

            if (eoc && eoc_d)
                check(0, "eoc high for more than one clock");

            if (rst_n_d && !eoc && result !== result_d)
                check(0, "result changed without eoc");

            if (idle_window)
                check(!sample && !comp_strobe && !eoc, "activity while idle");
        end
        sample_d = sample;
        eoc_d    = eoc;
        result_d = result;
        rst_n_d  = rst_n;
    end

    // ------------------------------------------------------------------
    // Stimulus helpers
    // ------------------------------------------------------------------
    // Static (not automatic) so the named fork can be disabled
    task wait_eoc;
        integer limit;
        begin
            limit = (SC + N) * div + 20;
            fork : wait_fork
                begin
                    @(posedge eoc);
                    disable wait_fork;
                end
                begin
                    repeat (limit) @(posedge clk);
                    check(0, "timed out waiting for eoc");
                    disable wait_fork;
                end
            join
        end
    endtask

    task automatic go_idle;
        begin
            repeat (3) @(posedge clk);
            #1 idle_window = 1;
        end
    endtask

    // One conversion started by a start pulse
    task automatic convert(input [N-1:0] v);
        begin
            vin = v;
            @(posedge clk) #1;
            idle_window = 0;
            start = 1;
            @(posedge clk) #1;
            start = 0;
            wait_eoc;
            go_idle;
        end
    endtask

    // Change timing only while idle
    task automatic set_timing(input [7:0] d, input [7:0] s);
        begin
            @(posedge clk) #1;
            div       = d;
            strobe_at = s;
        end
    endtask

    // Back-to-back conversions with start tied high, new input each time
    task automatic free_run(input integer count);
        integer i;
        begin
            vin = $random & MAX;
            prev_eoc_cyc = -1;
            @(posedge clk) #1;
            idle_window  = 0;
            free_running = 1;
            start        = 1;
            for (i = 0; i < count; i = i + 1) begin
                wait_eoc;
                vin = $random & MAX;  // held at the next sample fall
            end
            #1 start = 0;
            go_idle;
            free_running = 0;
        end
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    initial begin
        $timeformat(-9, 3, " ns", 0);

        // 1. Reset, then sit idle: nothing should fire
        repeat (3) @(posedge clk);
        #1 rst_n = 1;
        go_idle;
        repeat (10) @(posedge clk);

        // 2. Default timing: edge codes, walking bits, random codes
        convert(0);
        convert(MAX);
        convert(1);
        convert(MAX - 1);
        convert(1 << (N - 1));          // midscale
        convert((1 << (N - 1)) - 1);    // just below midscale
        convert((1 << (N - 1)) + 1);    // just above midscale
        convert(1234);
        for (k = 0; k < N; k = k + 1) begin
            convert(1 << k);
            convert(MAX ^ (1 << k));
        end
        repeat (40) convert($random & MAX);

        // 3. Other timing settings
        set_timing(8'd2,   8'd0);   // fastest legal
        convert(0); convert(MAX); repeat (5) convert($random & MAX);
        set_timing(8'd3,   8'd1);
        convert(0); convert(MAX); repeat (5) convert($random & MAX);
        set_timing(8'd12,  8'd10);  // latest legal strobe (div - 2)
        convert(0); convert(MAX); repeat (5) convert($random & MAX);
        set_timing(8'd20,  8'd0);   // earliest strobe
        convert(0); convert(MAX); repeat (5) convert($random & MAX);
        set_timing(8'd255, 8'd100); // slowest
        convert(0); convert(MAX); repeat (3) convert($random & MAX);
        set_timing(8'd12,  8'd8);   // back to default

        // 4. Free-running: start tied high
        free_run(10);

        // 5. Reset in the middle of a conversion, then convert again
        vin = 12'd3000;
        @(posedge clk) #1;
        idle_window = 0;
        start = 1;
        @(posedge clk) #1;
        start = 0;
        @(negedge sample);                  // now converting
        repeat (5 * div) @(posedge clk);
        #1 rst_n = 0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1;
        go_idle;
        convert(12'd1500);

        // Summary
        $display("--------------------------------------------");
        if (errors == 0)
            $display("ALL TESTS PASSED (%0d checks, %0d conversions)", checks, conversions);
        else
            $display("%0d FAILURES out of %0d checks (%0d conversions)",
                     errors, checks, conversions);
        if (sample_strobes > 0)
            $display("NOTE: comp_strobe pulsed %0d times during sampling (bit_timer runs whenever busy)",
                     sample_strobes);
        $display("--------------------------------------------");
        $finish;
    end

    // Safety net in case something hangs
    initial begin
        #20_000_000;   // 20 ms
        $display("WATCHDOG: simulation ran too long, stopping");
        $finish;
    end
endmodule
