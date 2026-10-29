`timescale 1ns/1ps

// Self-checking testbench for sar_fsm (differential, 12-bit, conventional switching)
//
// The comparator is modeled behaviorally:
//   vdac_diff = (2*code/2^N - 1) * VREF      (this is Vdacp - Vdacn for conventional switching)
//   comp_out  = (vin_diff >= vdac_diff)
//
// Expected output code (offset binary):
//   floor((vin/VREF + 1) * 2^N / 2), clamped to 0 .. 2^N-1

module tb_sar_fsm;

    localparam int  N_MSB         = 6;
    localparam int  N_LSB         = 6;
    localparam int  N             = N_MSB + N_LSB;
    localparam int  SAMPLE_CYCLES = 3;
    localparam int  FULL          = 1 << N;
    localparam real VREF          = 1.8;
    localparam int  TIMEOUT       = 4 * (N + SAMPLE_CYCLES + 4);   // generous cycle limit per conversion

    // DUT signals
    logic clk = 1'b0;
    logic rst_n;
    logic start;
    logic comp_out;
    logic sample;
    logic eoc;
    logic [N-1:0] result;
    logic [N-1:0] dac_pos;
    logic [N-1:0] dac_neg;

    int errors = 0;
    int tests  = 0;

    // 100 MHz clock
    always #5 clk = ~clk;

    sar_fsm #(
        .N_MSB         (N_MSB),
        .N_LSB         (N_LSB),
        .N             (N),
        .SAMPLE_CYCLES (SAMPLE_CYCLES)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start),
        .comp_out (comp_out),
        .sample   (sample),
        .result   (result),
        .dac_pos  (dac_pos),
        .dac_neg  (dac_neg),
        .eoc      (eoc)
    );

    // ------------------------------------------------------------------
    // Behavioral comparator + DAC model
    // ------------------------------------------------------------------
    real vin  = 0.0;     // differential input, Vinp - Vinn
    real vdac;           // differential DAC output, Vdacp - Vdacn

    always_comb begin
        vdac     = (2.0 * $itor(dac_pos) / FULL - 1.0) * VREF;
        comp_out = (vin >= vdac);
    end

    // ------------------------------------------------------------------
    // Continuous check: N side must always be the inverse of the P side
    // ------------------------------------------------------------------
    always @(negedge clk) begin
        if (rst_n && (dac_neg !== ~dac_pos)) begin
            errors++;
            $display("[%0t] ERROR: dac_neg (%b) is not ~dac_pos (%b)", $time, dac_neg, dac_pos);
        end
    end

    // ------------------------------------------------------------------
    // Run one conversion and check the result
    // ------------------------------------------------------------------
    task automatic check_conversion(input real v);
        int expected;
        int got;
        int cycles;
        int sample_seen;

        vin      = v;
        expected = int'($floor((v / VREF + 1.0) * FULL / 2.0));
        if (expected < 0)        expected = 0;
        if (expected > FULL - 1) expected = FULL - 1;

        // one-cycle start pulse
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        // wait for eoc, counting sample cycles on the way
        cycles      = 0;
        sample_seen = 0;
        while (!eoc && cycles < TIMEOUT) begin
            if (sample) sample_seen++;
            @(negedge clk);
            cycles++;
        end

        tests++;
        got = int'(result);

        if (cycles >= TIMEOUT) begin
            errors++;
            $display("[%0t] ERROR: timeout waiting for eoc (vin = %f)", $time, v);
        end else begin
            if (got !== expected) begin
                errors++;
                $display("[%0t] ERROR: vin = %f  expected = %0d  got = %0d", $time, v, expected, got);
            end
            if (sample_seen !== SAMPLE_CYCLES) begin
                errors++;
                $display("[%0t] ERROR: sample was high %0d cycles, expected %0d", $time, sample_seen, SAMPLE_CYCLES);
            end
            // eoc must be a 1-cycle pulse
            @(negedge clk);
            if (eoc) begin
                errors++;
                $display("[%0t] ERROR: eoc stayed high for more than one cycle", $time);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Stimulus
    // ------------------------------------------------------------------
    real v_rand;
    real v_k;

    initial begin
        $dumpfile("tb_sar_fsm.vcd");
        $dumpvars(0, tb_sar_fsm);

        // ---- reset ----
        rst_n = 1'b0;
        start = 1'b0;
        repeat (3) @(negedge clk);
        if (result !== '0 || eoc !== 1'b0 || sample !== 1'b0) begin
            errors++;
            $display("ERROR: outputs not cleared during reset");
        end
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // ---- directed tests: endpoints, mid-scale, small offsets ----
        $display("Directed tests...");
        check_conversion(-VREF);                       // bottom of range -> code 0
        check_conversion( VREF);                       // top of range    -> code max (clamped)
        check_conversion( 0.0);                        // mid-scale       -> code 2048
        check_conversion( 0.5 * VREF);
        check_conversion(-0.5 * VREF);
        check_conversion( 1.0e-4);
        check_conversion(-1.0e-4);
        check_conversion( 2.0 * VREF);                 // overrange high -> clamp to max
        check_conversion(-2.0 * VREF);                 // overrange low  -> clamp to 0

        // ---- full sweep: one input in the middle of every code bin ----
        $display("Sweeping all %0d codes...", FULL);
        for (int k = 0; k < FULL; k++) begin
            v_k = ((k + 0.5) / (FULL / 2.0) - 1.0) * VREF;
            check_conversion(v_k);
        end

        // ---- random inputs ----
        $display("Random tests...");
        for (int i = 0; i < 2000; i++) begin
            v_rand = (($urandom % 1000000) / 1000000.0 * 2.0 - 1.0) * VREF;
            check_conversion(v_rand);
        end

        // ---- summary ----
        $display("--------------------------------------------");
        $display("Tests run: %0d   Errors: %0d", tests, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $display("--------------------------------------------");
        $finish;
    end

    // Global watchdog in case something hangs
    initial begin
        #(100_000_000);
        $display("ERROR: global timeout");
        $finish;
    end

endmodule
