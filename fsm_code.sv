// SAR ADC controller (charge-redistribution type)
// Binary search, one bit per clock, MSB first.
//
// comp_out polarity: 1 = Vin >= Vdac (trial bit is kept)
//                    0 = Vin <  Vdac (trial bit is cleared)

module sar_fsm #(
    parameter int N             = 10,  // resolution in bits (N >= 2)
    parameter int SAMPLE_CYCLES = 2    // clock cycles spent tracking the input (assumption) 
)(
    input  logic clk,
    input  logic rst_n,        // active-low async reset
    input  logic start,        // pulse to begin a conversion
    input  logic comp_out,     // comparator decision

    output logic sample,       // closes the sampling switch
    output logic [N-1:0] dac_code,     // drives the capacitor array
    output logic [N-1:0] result,       // final conversion result
    output logic eoc        // end of conversion (1-cycle pulse)
);

    /* ------------------------------------------------------------------
State definitions and overviews:
IDLE - waits for conversion request
dac_code = 0
bit_idx = MSB
sample_cnt cleared
Moves to SAMPLE when start = 1.

SAMPLE - tracks input
sample = 1, capacitor is closed and Vin flows in
Stays until SAMPLE_CYCLES clock finishes using sample_cnt
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
    typedef enum logic [1:0] {
        S_IDLE,
        S_SAMPLE,
        S_CONVERT,
        S_DONE
    } state_t;

    state_t state, next_state;

    // Counters
    logic [$clog2(N)-1:0] bit_idx;     // bit under test, N-1 down to 0
    logic [$clog2(SAMPLE_CYCLES+1)-1:0] sample_cnt; 	// clocks spent sampling

    // First trial code: only the MSB set (half of full scale)
    localparam logic [N-1:0] MSB_ONLY = N'(1) << (N-1);

    // ------------------------------------------------------------------
    // State register
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // ------------------------------------------------------------------
    // Next-state logic
    // ------------------------------------------------------------------
    always_comb begin
        next_state = state;
        unique case (state)
            S_IDLE:    if (start)                           next_state = S_SAMPLE;
            S_SAMPLE:  if (sample_cnt == SAMPLE_CYCLES - 1) next_state = S_CONVERT;
            S_CONVERT: if (bit_idx == 0)                    next_state = S_DONE;
            S_DONE:                                         next_state = S_IDLE;
            default:                                        next_state = S_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Output that depends only on state (Moore output)
    // ------------------------------------------------------------------
    assign sample = (state == S_SAMPLE);

    // ------------------------------------------------------------------
    // Datapath: guess register, bit counter, result
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dac_code   <= '0;
            result     <= '0;
            eoc        <= 1'b0;
            bit_idx    <= N - 1;
            sample_cnt <= '0;
        end else begin
            eoc <= 1'b0;                       // default: pulse only in DONE

            unique case (state)
                S_IDLE: begin
                    dac_code   <= '0;
                    bit_idx    <= N - 1;
                    sample_cnt <= '0;
                end

                S_SAMPLE: begin
                    sample_cnt <= sample_cnt + 1'b1;
                    dac_code   <= MSB_ONLY;    // preload first trial
                    bit_idx    <= N - 1;
                end

                S_CONVERT: begin
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
