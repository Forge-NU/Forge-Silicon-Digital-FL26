// SAR ADC controller, differential, 6+6 split-capacitor CDAC
// Conventional (complementary) switching: P side gets the code, N side gets ~code.
// Binary search, one bit per clock, MSB first.
//
// comp_out polarity: 1 = (Vinp - Vinn) >= (Vdacp - Vdacn)  (trial bit is kept)
//                    0 = (Vinp - Vinn) <  (Vdacp - Vdacn)  (trial bit is cleared)
//
// Output code is offset binary: 0 = -Vref, mid-scale = 0 V differential,
// all ones = +Vref. Invert result[N-1] downstream if two's complement is needed.
`timescale 1ns/1ps
module sar_fsm #(
    parameter N_MSB         = 6, 	// bits in the MSB sub-array
    parameter N_LSB         = 6, 	// bits in the LSB sub-array
    parameter N             = N_MSB + N_LSB, 	// total resolution (12)
    parameter SAMPLE_CYCLES = 2  // clock cycles spent tracking the input (assumption)
)(
    input  wire clk,
    input  wire rst_n,	// active-low async reset
    input  wire start, // pulse to begin a conversion
    input  wire step,  // from bit_timer
    input  wire comp_out, 	// comparator decision

    output wire sample,  // closes the sampling switches (overrides code at the switch driver)
    output wire busy,    // to bit_timer enable
    output reg  [N-1:0] result,        // final conversion result (offset binary)
    output wire [N-1:0] dac_pos,       // P-side capacitor switch controls
    output wire [N-1:0] dac_neg,       // N-side controls (inverse of dac_pos)
    output reg  eoc	 // end of conversion (1-cycle pulse)
);

    /* ------------------------------------------------------------------
State definitions and overviews:
IDLE - waits for conversion request
dac_code = 0 (dac_pos all 0, dac_neg all 1)
bit_idx = MSB
sample_cnt cleared
Moves to SAMPLE when start = 1.

SAMPLE - tracks input
sample = 1, bottom plates connect to Vinp / Vinn (switch driver gives
sample priority over the code bits)
Stays until SAMPLE_CYCLES clocks finish using sample_cnt
Pre-loads dac_code with first trial value MSB_ONLY
Moves to CONVERT

CONVERT - Executes binary search
One bit per clock with MSB first
sample = 0 so input is held
Each clock:
comparator output decides current trial bit value
If not the last bit the next trial bit is set to 1 and bit_idx goes down one
Moves to DONE after clock where bit_idx = 0 (LSB was figured out)

DONE - hands off answer
dac_code has final version
dac_code copied into result
eoc is set
Goes to IDLE after 1 clock cycle
       ------------------------------------------------------------------ */
    localparam [1:0] S_IDLE    = 2'd0,
                     S_SAMPLE  = 2'd1,
                     S_CONVERT = 2'd2,
                     S_DONE    = 2'd3;

    reg [1:0] state, next_state;

    // Internal trial register for guess
    reg [N-1:0] dac_code;

    // Counters
    reg [$clog2(N)-1:0] bit_idx;	 // bit under test, N-1 down to 0
    reg [$clog2(SAMPLE_CYCLES+1)-1:0] sample_cnt;      // clocks spent sampling

    // First trial code: only the MSB set (P side), N side is the inverse
    localparam [N-1:0] MSB_ONLY = {1'b1, {(N-1){1'b0}}};

    // ------------------------------------------------------------------
    // State register
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // ------------------------------------------------------------------
    // Next-state logic
    // ------------------------------------------------------------------
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:    if (start)   next_state = S_SAMPLE;
            S_SAMPLE:  if (step && sample_cnt == SAMPLE_CYCLES - 1) next_state = S_CONVERT;
            S_CONVERT: if (step && bit_idx == 0) next_state = S_DONE;
            S_DONE:   next_state = S_IDLE;
            default:  next_state = S_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Outputs that depend only on state / the trial register
    // ------------------------------------------------------------------
    assign sample  = (state == S_SAMPLE);
    assign busy    = (state != S_IDLE);
    assign dac_pos = dac_code;
    assign dac_neg = ~dac_code;

    // ------------------------------------------------------------------
    // Datapath: guess register, bit counter, result
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dac_code   <= {N{1'b0}};
            result     <= {N{1'b0}};
            eoc        <= 1'b0;
            bit_idx    <= N - 1;
            sample_cnt <= 0;
        end else begin
            eoc <= 1'b0; // default: pulse only in DONE

            case (state)
                S_IDLE: begin
                    dac_code   <= {N{1'b0}};
                    bit_idx    <= N - 1;
                    sample_cnt <= 0;
                end

                S_SAMPLE: begin
                    if (step) sample_cnt <= sample_cnt + 1'b1;
                    dac_code   <= MSB_ONLY;    // preload first trial
                    bit_idx    <= N - 1;
                end

                S_CONVERT: if (step) begin
                    // Keep the trial bit if comparator says 1, clear it if 0
                    dac_code[bit_idx] <= comp_out;

                    // Set up the next lower trial bit
                    if (bit_idx != 0) begin
                        dac_code[bit_idx - 1] <= 1'b1;
                        bit_idx               <= bit_idx - 1'b1;
                    end
                end

                S_DONE: begin
                    result <= dac_code;        // dac_code holds the final answer
                    eoc    <= 1'b1;
                end

                default: ;
            endcase
        end
    end

endmodule
