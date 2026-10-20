`timescale 1ns/1ps

module fft8_pipeline #(
    parameter WIDTH = 24,
    parameter FRAC  = 15
)(
    input  logic clk,
    input  logic rst_n,
    input  logic in_valid,

    // All inputs use fixed-point with FRAC fractional bits
    input  logic signed [WIDTH-1:0] x_r [0:7],
    input  logic signed [WIDTH-1:0] x_i [0:7],

    output logic out_valid,

    // WIDTH + 3 bits for 8-point FFT growth
    output logic signed [WIDTH+2:0] X0_r,
    output logic signed [WIDTH+2:0] X0_i,

    output logic signed [WIDTH+2:0] X1_r,
    output logic signed [WIDTH+2:0] X1_i,

    output logic signed [WIDTH+2:0] X2_r,
    output logic signed [WIDTH+2:0] X2_i,

    output logic signed [WIDTH+2:0] X3_r,
    output logic signed [WIDTH+2:0] X3_i,

    output logic signed [WIDTH+2:0] X4_r,
    output logic signed [WIDTH+2:0] X4_i,

    output logic signed [WIDTH+2:0] X5_r,
    output logic signed [WIDTH+2:0] X5_i,

    output logic signed [WIDTH+2:0] X6_r,
    output logic signed [WIDTH+2:0] X6_i,

    output logic signed [WIDTH+2:0] X7_r,
    output logic signed [WIDTH+2:0] X7_i
);

    // ============================================================
    // Internal data width
    // ============================================================

    localparam IW = WIDTH + 3;


    // ============================================================
    // Twiddle constant
    //
    // 1/sqrt(2) = 0.70710678...
    //
    // Q15 representation:
    //
    // 0.70710678 * 32768 ≈ 23170
    // ============================================================

    localparam logic signed [IW-1:0] TW_C = 23170;


    // ============================================================
    // Sign extension function
    // ============================================================

    function automatic logic signed [IW-1:0] extend_input(
        input logic signed [WIDTH-1:0] value
    );

        extend_input = {
            {(IW-WIDTH){value[WIDTH-1]}},
            value
        };

    endfunction


    // ============================================================
    // Pipeline valid signals
    // ============================================================

    logic valid_s1;
    logic valid_s2;
    logic valid_s3;


    // ============================================================
    // Stage 1 registers
    // ============================================================

    logic signed [IW-1:0] s1_r [0:7];
    logic signed [IW-1:0] s1_i [0:7];


    // ============================================================
    // Stage 2 registers
    // ============================================================

    logic signed [IW-1:0] s2_r [0:7];
    logic signed [IW-1:0] s2_i [0:7];


    // ============================================================
    // Stage 3 twiddle values
    // ============================================================

    logic signed [IW-1:0] tw_r [0:3];
    logic signed [IW-1:0] tw_i [0:3];


    // ============================================================
    // STAGE 1
    //
    // Four 2-point FFTs
    //
    // (x0,x4)
    // (x2,x6)
    // (x1,x5)
    // (x3,x7)
    // ============================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            valid_s1 <= 1'b0;

            for (int i = 0; i < 8; i++) begin
                s1_r[i] <= '0;
                s1_i[i] <= '0;
            end

        end

        else begin

            valid_s1 <= in_valid;

            if (in_valid) begin

                // Butterfly 0: x0, x4
                s1_r[0] <= extend_input(x_r[0])
                         + extend_input(x_r[4]);

                s1_i[0] <= extend_input(x_i[0])
                         + extend_input(x_i[4]);

                s1_r[1] <= extend_input(x_r[0])
                         - extend_input(x_r[4]);

                s1_i[1] <= extend_input(x_i[0])
                         - extend_input(x_i[4]);


                // Butterfly 1: x2, x6
                s1_r[2] <= extend_input(x_r[2])
                         + extend_input(x_r[6]);

                s1_i[2] <= extend_input(x_i[2])
                         + extend_input(x_i[6]);

                s1_r[3] <= extend_input(x_r[2])
                         - extend_input(x_r[6]);

                s1_i[3] <= extend_input(x_i[2])
                         - extend_input(x_i[6]);


                // Butterfly 2: x1, x5
                s1_r[4] <= extend_input(x_r[1])
                         + extend_input(x_r[5]);

                s1_i[4] <= extend_input(x_i[1])
                         + extend_input(x_i[5]);

                s1_r[5] <= extend_input(x_r[1])
                         - extend_input(x_r[5]);

                s1_i[5] <= extend_input(x_i[1])
                         - extend_input(x_i[5]);


                // Butterfly 3: x3, x7
                s1_r[6] <= extend_input(x_r[3])
                         + extend_input(x_r[7]);

                s1_i[6] <= extend_input(x_i[3])
                         + extend_input(x_i[7]);

                s1_r[7] <= extend_input(x_r[3])
                         - extend_input(x_r[7]);

                s1_i[7] <= extend_input(x_i[3])
                         - extend_input(x_i[7]);

            end

        end

    end


    // ============================================================
    // STAGE 2
    //
    // Creates:
    //
    // E[0..3] = 4-point FFT of even samples
    // O[0..3] = 4-point FFT of odd samples
    //
    // W4^0 = 1
    // W4^1 = -j
    // ============================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            valid_s2 <= 1'b0;

            for (int i = 0; i < 8; i++) begin
                s2_r[i] <= '0;
                s2_i[i] <= '0;
            end

        end

        else begin

            valid_s2 <= valid_s1;

            if (valid_s1) begin

                // =================================================
                // EVEN 4-POINT FFT
                // =================================================

                // W4^0 = 1

                s2_r[0] <= s1_r[0] + s1_r[2];
                s2_i[0] <= s1_i[0] + s1_i[2];

                s2_r[2] <= s1_r[0] - s1_r[2];
                s2_i[2] <= s1_i[0] - s1_i[2];


                // W4^1 = -j
                //
                // (a + jb)(-j)
                //
                // = b - ja

                s2_r[1] <= s1_r[1] + s1_i[3];
                s2_i[1] <= s1_i[1] - s1_r[3];

                s2_r[3] <= s1_r[1] - s1_i[3];
                s2_i[3] <= s1_i[1] + s1_r[3];


                // =================================================
                // ODD 4-POINT FFT
                // =================================================

                s2_r[4] <= s1_r[4] + s1_r[6];
                s2_i[4] <= s1_i[4] + s1_i[6];

                s2_r[6] <= s1_r[4] - s1_r[6];
                s2_i[6] <= s1_i[4] - s1_i[6];


                // W4^1 = -j

                s2_r[5] <= s1_r[5] + s1_i[7];
                s2_i[5] <= s1_i[5] - s1_r[7];

                s2_r[7] <= s1_r[5] - s1_i[7];
                s2_i[7] <= s1_i[5] + s1_r[7];

            end

        end

    end


    // ============================================================
    // STAGE 3
    //
    // W8^0 = 1
    // W8^1 =  c - jc
    // W8^2 = -j
    // W8^3 = -c - jc
    //
    // c = 1/sqrt(2)
    // ============================================================


    // Multiplication temporary values

    logic signed [2*IW-1:0] p1_a;
    logic signed [2*IW-1:0] p1_b;

    logic signed [2*IW-1:0] p3_a;
    logic signed [2*IW-1:0] p3_b;

    logic signed [2*IW:0] w1_real_temp;
    logic signed [2*IW:0] w1_imag_temp;

    logic signed [2*IW:0] w3_real_temp;
    logic signed [2*IW:0] w3_imag_temp;


    always_comb begin

        // --------------------------------------------------------
        // W8^0 = 1
        // --------------------------------------------------------

        tw_r[0] = s2_r[4];
        tw_i[0] = s2_i[4];


        // --------------------------------------------------------
        // W8^1 = c - jc
        //
        // (a + jb)(c - jc)
        //
        // real = c(a+b)
        // imag = c(b-a)
        // --------------------------------------------------------

        p1_a = s2_r[5] * TW_C;
        p1_b = s2_i[5] * TW_C;

        w1_real_temp =
            $signed(p1_a)
            +
            $signed(p1_b);

        w1_imag_temp =
            $signed(p1_b)
            -
            $signed(p1_a);

        tw_r[1] = w1_real_temp >>> FRAC;
        tw_i[1] = w1_imag_temp >>> FRAC;


        // --------------------------------------------------------
        // W8^2 = -j
        // --------------------------------------------------------

        tw_r[2] =  s2_i[6];
        tw_i[2] = -s2_r[6];


        // --------------------------------------------------------
        // W8^3 = -c - jc
        //
        // real = c(b-a)
        // imag = -c(a+b)
        // --------------------------------------------------------

        p3_a = s2_r[7] * TW_C;
        p3_b = s2_i[7] * TW_C;

        w3_real_temp =
            $signed(p3_b)
            -
            $signed(p3_a);

        w3_imag_temp =
            -$signed(p3_a)
            -
            $signed(p3_b);

        tw_r[3] = w3_real_temp >>> FRAC;
        tw_i[3] = w3_imag_temp >>> FRAC;

    end


    // ============================================================
    // FINAL PIPELINE REGISTER
    //
    // X[k]   = E[k] + W8^k O[k]
    // X[k+4] = E[k] - W8^k O[k]
    // ============================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            valid_s3 <= 1'b0;

            X0_r <= '0;
            X0_i <= '0;

            X1_r <= '0;
            X1_i <= '0;

            X2_r <= '0;
            X2_i <= '0;

            X3_r <= '0;
            X3_i <= '0;

            X4_r <= '0;
            X4_i <= '0;

            X5_r <= '0;
            X5_i <= '0;

            X6_r <= '0;
            X6_i <= '0;

            X7_r <= '0;
            X7_i <= '0;

        end

        else begin

            valid_s3 <= valid_s2;

            if (valid_s2) begin

                // k = 0

                X0_r <= s2_r[0] + tw_r[0];
                X0_i <= s2_i[0] + tw_i[0];

                X4_r <= s2_r[0] - tw_r[0];
                X4_i <= s2_i[0] - tw_i[0];


                // k = 1

                X1_r <= s2_r[1] + tw_r[1];
                X1_i <= s2_i[1] + tw_i[1];

                X5_r <= s2_r[1] - tw_r[1];
                X5_i <= s2_i[1] - tw_i[1];


                // k = 2

                X2_r <= s2_r[2] + tw_r[2];
                X2_i <= s2_i[2] + tw_i[2];

                X6_r <= s2_r[2] - tw_r[2];
                X6_i <= s2_i[2] - tw_i[2];


                // k = 3

                X3_r <= s2_r[3] + tw_r[3];
                X3_i <= s2_i[3] + tw_i[3];

                X7_r <= s2_r[3] - tw_r[3];
                X7_i <= s2_i[3] - tw_i[3];

            end

        end

    end


    assign out_valid = valid_s3;

endmodule