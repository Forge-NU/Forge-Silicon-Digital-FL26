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
    localparam int N   = 12;
    localparam int SC  = 2;            // SAMPLE_CYCLES
    localparam int MAX = (1 << N) - 1;

    logic         clk = 0, rst_n = 0, start = 0;
    logic [7:0]   div = 8'd12, strobe_at = 8'd8;
    logic         comp_out;            // starts as X until the first strobe
    logic         sample, comp_strobe, eoc;
    logic [N-1:0] dac_code, result;

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
    logic [N-1:0] vin = '0;            // input "voltage" as a code
    logic [N-1:0] vin_held;            // what the sample-and-hold captured

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
    int errors = 0, checks = 0, conversions = 0, sample_strobes = 0;
    int cyc = 0;                       // clock edge counter
    int start_cyc = 0;                 // cyc when the current conversion began
    int prev_eoc_cyc = -1;
    bit idle_window  = 0;              // stimulus says the DUT should be idle
    bit free_running = 0;
    logic         sample_d = 0, eoc_d = 0, rst_n_d = 0;
    logic [N-1:0] result_d;

    always @(posedge clk) cyc++;

    task automatic check(input bit cond, input string msg);
        checks++;
        if (!cond) begin
            errors++;
            $display("FAIL @ %t: %s (div=%0d, strobe_at=%0d)",
                     $realtime, msg, div, strobe_at);
        end
    endtask

    // ------------------------------------------------------------------
    // Monitor: look at the outputs in the middle of every clock cycle
    // ------------------------------------------------------------------
    always @(negedge clk) begin
        if (!rst_n) begin
            check(!sample && !comp_strobe && !eoc && result == '0 && dac_code == '0,
                  "outputs not cleared during reset");
        end else begin
            if (sample && !sample_d)
                start_cyc = cyc;

            if (!sample && sample_d)
                check(cyc - start_cyc == SC * div + 1,
                      $sformatf("sample window was %0d clocks, expected %0d",
                                cyc - start_cyc, SC * div + 1));

            if (sample && comp_strobe)
                sample_strobes++;

            if (eoc && !eoc_d) begin
                conversions++;
                check(result === vin_held,
                      $sformatf("result = %0d, expected %0d", result, vin_held));
                check(cyc - start_cyc == (SC + N) * div + 2,
                      $sformatf("conversion took %0d clocks, expected %0d",
                                cyc - start_cyc, (SC + N) * div + 2));
                if (free_running && prev_eoc_cyc >= 0)
                    check(cyc - prev_eoc_cyc == (SC + N) * div + 3,
                          $sformatf("eoc spacing was %0d clocks, expected %0d",
                                    cyc - prev_eoc_cyc, (SC + N) * div + 3));
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
    task automatic wait_eoc();
        int limit = (SC + N) * div + 20;
        fork
            @(posedge eoc);
            begin
                repeat (limit) @(posedge clk);
                check(0, "timed out waiting for eoc");
            end
        join_any
        disable fork;
    endtask

    task automatic go_idle();
        repeat (3) @(posedge clk);
        #1 idle_window = 1;
    endtask

    // One conversion started by a start pulse
    task automatic convert(input logic [N-1:0] v);
        vin = v;
        @(posedge clk) #1;
        idle_window = 0;
        start = 1;
        @(posedge clk) #1;
        start = 0;
        wait_eoc();
        go_idle();
    endtask

    // Change timing only while idle
    task automatic set_timing(input logic [7:0] d, input logic [7:0] s);
        @(posedge clk) #1;
        div       = d;
        strobe_at = s;
    endtask

    // Back-to-back conversions with start tied high, new input each time
    task automatic free_run(input int count);
        vin = $urandom_range(MAX, 0);
        prev_eoc_cyc = -1;
        @(posedge clk) #1;
        idle_window  = 0;
        free_running = 1;
        start        = 1;
        for (int i = 0; i < count; i++) begin
            wait_eoc();
            vin = $urandom_range(MAX, 0);  // held at the next sample fall
        end
        #1 start = 0;
        go_idle();
        free_running = 0;
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    initial begin
        $timeformat(-9, 3, " ns", 0);

        // 1. Reset, then sit idle: nothing should fire
        repeat (3) @(posedge clk);
        #1 rst_n = 1;
        go_idle();
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
        for (int k = 0; k < N; k++) begin
            convert(1 << k);
            convert(MAX ^ (1 << k));
        end
        repeat (40) convert($urandom_range(MAX, 0));

        // 3. Other timing settings
        set_timing(8'd2,   8'd0);   // fastest legal
        convert(0); convert(MAX); repeat (5) convert($urandom_range(MAX, 0));
        set_timing(8'd3,   8'd1);
        convert(0); convert(MAX); repeat (5) convert($urandom_range(MAX, 0));
        set_timing(8'd12,  8'd10);  // latest legal strobe (div - 2)
        convert(0); convert(MAX); repeat (5) convert($urandom_range(MAX, 0));
        set_timing(8'd20,  8'd0);   // earliest strobe
        convert(0); convert(MAX); repeat (5) convert($urandom_range(MAX, 0));
        set_timing(8'd255, 8'd100); // slowest
        convert(0); convert(MAX); repeat (3) convert($urandom_range(MAX, 0));
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
        go_idle();
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
        #20ms;
        $display("WATCHDOG: simulation ran too long, stopping");
        $finish;
    end
endmodule
