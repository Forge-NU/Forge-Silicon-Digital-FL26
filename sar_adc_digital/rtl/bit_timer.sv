`timescale 1ns/1ps
module bit_timer (
    input  logic       clk,
    input  logic       rst_n,        // active-low async reset
    input  logic       enable,       // runs only while the FSM is busy
    input  logic [7:0] div,          // clk cycles per step (>= 2)
    input  logic [7:0] strobe_at,    // clk cycle within a step to strobe the comparator (<= div - 2)
    output logic       step,         // one pulse per step: FSM advances
    output logic       comp_strobe   // one pulse per step: comparator decides
);
    logic [7:0] clk_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt     <= '0;
            step        <= 1'b0;
            comp_strobe <= 1'b0;
        end else if (!enable) begin
            clk_cnt     <= '0;
            step        <= 1'b0;
            comp_strobe <= 1'b0;
        end else begin
            step        <= (clk_cnt == div - 1);
            comp_strobe <= (clk_cnt == strobe_at);
            clk_cnt     <= (clk_cnt == div - 1) ? '0 : clk_cnt + 1'b1;
        end
    end
endmodule
