`timescale 1ns/1ps

module fft8_pipeline_tb;

    localparam WIDTH = 24;
    localparam FRAC  = 15;
    localparam IW    = WIDTH + 3;

    localparam real SCALE = 32768.0;


    logic clk;
    logic rst_n;

    logic in_valid;
    logic out_valid;


    // ============================================================
    // INPUTS
    // ============================================================

    logic signed [WIDTH-1:0] x_r [0:7];
    logic signed [WIDTH-1:0] x_i [0:7];


    // ============================================================
    // DUT OUTPUTS
    // ============================================================

    logic signed [IW-1:0] X0_r, X0_i;
    logic signed [IW-1:0] X1_r, X1_i;
    logic signed [IW-1:0] X2_r, X2_i;
    logic signed [IW-1:0] X3_r, X3_i;

    logic signed [IW-1:0] X4_r, X4_i;
    logic signed [IW-1:0] X5_r, X5_i;
    logic signed [IW-1:0] X6_r, X6_i;
    logic signed [IW-1:0] X7_r, X7_i;


    // ============================================================
    // INTERNAL TESTBENCH ARRAYS
    //
    // Only used to make check_bin_real() easier.
    // ============================================================

    logic signed [IW-1:0] X_r [0:7];
    logic signed [IW-1:0] X_i [0:7];


    always_comb begin

        X_r[0] = X0_r;
        X_i[0] = X0_i;

        X_r[1] = X1_r;
        X_i[1] = X1_i;

        X_r[2] = X2_r;
        X_i[2] = X2_i;

        X_r[3] = X3_r;
        X_i[3] = X3_i;

        X_r[4] = X4_r;
        X_i[4] = X4_i;

        X_r[5] = X5_r;
        X_i[5] = X5_i;

        X_r[6] = X6_r;
        X_i[6] = X6_i;

        X_r[7] = X7_r;
        X_i[7] = X7_i;

    end


    // ============================================================
    // DUT
    // ============================================================

    fft8_pipeline #(
        .WIDTH(WIDTH),
        .FRAC(FRAC)
    ) dut (

        .clk(clk),
        .rst_n(rst_n),

        .in_valid(in_valid),

        .x_r(x_r),
        .x_i(x_i),

        .out_valid(out_valid),

        .X0_r(X0_r),
        .X0_i(X0_i),

        .X1_r(X1_r),
        .X1_i(X1_i),

        .X2_r(X2_r),
        .X2_i(X2_i),

        .X3_r(X3_r),
        .X3_i(X3_i),

        .X4_r(X4_r),
        .X4_i(X4_i),

        .X5_r(X5_r),
        .X5_i(X5_i),

        .X6_r(X6_r),
        .X6_i(X6_i),

        .X7_r(X7_r),
        .X7_i(X7_i)

    );


    // ============================================================
    // CLOCK
    //
    // 10 ns period
    // ============================================================

    always #5 clk = ~clk;


    // ============================================================
    // CONVERT INTEGER TO FIXED POINT
    //
    // Example:
    //
    // 1 -> 32768
    // 2 -> 65536
    // ============================================================

    function automatic logic signed [WIDTH-1:0] to_fixed(
        input integer value
    );

        to_fixed = value <<< FRAC;

    endfunction


    // ============================================================
    // APPLY REAL INPUT VECTOR
    // ============================================================

    task apply_real_input(
        input integer a0,
        input integer a1,
        input integer a2,
        input integer a3,
        input integer a4,
        input integer a5,
        input integer a6,
        input integer a7
    );

        begin

            @(negedge clk);

            x_r[0] = to_fixed(a0);
            x_r[1] = to_fixed(a1);
            x_r[2] = to_fixed(a2);
            x_r[3] = to_fixed(a3);

            x_r[4] = to_fixed(a4);
            x_r[5] = to_fixed(a5);
            x_r[6] = to_fixed(a6);
            x_r[7] = to_fixed(a7);


            for (int i = 0; i < 8; i++) begin

                x_i[i] = '0;

            end


            in_valid = 1'b1;

            @(negedge clk);

            in_valid = 1'b0;

        end

    endtask


    // ============================================================
    // WAIT UNTIL FFT OUTPUT IS READY
    // ============================================================

    task wait_for_output;

        begin

            do begin

                @(posedge clk);
                #1;

            end
            while (out_valid !== 1'b1);

        end

    endtask


    // ============================================================
    // CHECK ONE COMPLEX FFT BIN
    //
    // Converts fixed-point result back into a real number.
    // ============================================================

    task check_bin_real(
        input integer index,

        input real expected_r,
        input real expected_i,

        input real tolerance
    );

        real actual_r;
        real actual_i;

        real error_r;
        real error_i;

        begin

            actual_r =
                $itor($signed(X_r[index])) / SCALE;

            actual_i =
                $itor($signed(X_i[index])) / SCALE;


            error_r = actual_r - expected_r;
            error_i = actual_i - expected_i;


            if (error_r < 0.0)
                error_r = -error_r;

            if (error_i < 0.0)
                error_i = -error_i;


            if (
                (error_r <= tolerance) &&
                (error_i <= tolerance)
            ) begin

                $display(
                    "PASS X[%0d] expected %0.6f + j%0.6f   got %0.6f + j%0.6f",
                    index,
                    expected_r,
                    expected_i,
                    actual_r,
                    actual_i
                );

            end

            else begin

                $display(
                    "FAIL X[%0d] expected %0.6f + j%0.6f   got %0.6f + j%0.6f",
                    index,
                    expected_r,
                    expected_i,
                    actual_r,
                    actual_i
                );

            end

        end

    endtask


    // ============================================================
    // PRINT COMPLETE FFT
    // ============================================================

    task print_fft;

        real actual_r;
        real actual_i;

        begin

            for (int i = 0; i < 8; i++) begin

                actual_r =
                    $itor($signed(X_r[i])) / SCALE;

                actual_i =
                    $itor($signed(X_i[i])) / SCALE;


                $display(
                    "X[%0d] = %0.6f + j%0.6f",
                    i,
                    actual_r,
                    actual_i
                );

            end

        end

    endtask


    // ============================================================
    // MAIN TEST
    // ============================================================

    initial begin

        // --------------------------------------------------------
        // INITIAL CONDITIONS
        // --------------------------------------------------------

        clk      = 1'b0;
        rst_n    = 1'b0;
        in_valid = 1'b0;


        for (int i = 0; i < 8; i++) begin

            x_r[i] = '0;
            x_i[i] = '0;

        end


        // --------------------------------------------------------
        // RESET
        // --------------------------------------------------------

        repeat (3) @(posedge clk);

        @(negedge clk);

        rst_n = 1'b1;

        @(posedge clk);


        // ========================================================
        // TEST 1
        //
        // IMPULSE
        //
        // x = [1 0 0 0 0 0 0 0]
        //
        // FFT:
        //
        // [1 1 1 1 1 1 1 1]
        // ========================================================

        $display("");
        $display("==============================");
        $display("TEST 1: IMPULSE");
        $display("==============================");


        apply_real_input(
            1,0,0,0,
            0,0,0,0
        );


        wait_for_output();


        for (int i = 0; i < 8; i++) begin

            check_bin_real(
                i,
                1.0,
                0.0,
                0.0001
            );

        end


        // ========================================================
        // TEST 2
        //
        // DC SIGNAL
        //
        // x = [1 1 1 1 1 1 1 1]
        //
        // FFT:
        //
        // X0 = 8
        // everything else = 0
        // ========================================================

        $display("");
        $display("==============================");
        $display("TEST 2: DC SIGNAL");
        $display("==============================");


        apply_real_input(
            1,1,1,1,
            1,1,1,1
        );


        wait_for_output();


        check_bin_real(
            0,
            8.0,
            0.0,
            0.0001
        );


        for (int i = 1; i < 8; i++) begin

            check_bin_real(
                i,
                0.0,
                0.0,
                0.0001
            );

        end


        // ========================================================
        // TEST 3
        //
        // ALTERNATING SIGNAL
        //
        // x =
        //
        // [1 -1 1 -1 1 -1 1 -1]
        //
        // FFT:
        //
        // X4 = 8
        //
        // everything else = 0
        // ========================================================

        $display("");
        $display("==============================");
        $display("TEST 3: ALTERNATING");
        $display("==============================");


        apply_real_input(
             1,-1, 1,-1,
             1,-1, 1,-1
        );


        wait_for_output();


        for (int i = 0; i < 8; i++) begin

            if (i == 4) begin

                check_bin_real(
                    i,
                    8.0,
                    0.0,
                    0.0001
                );

            end

            else begin

                check_bin_real(
                    i,
                    0.0,
                    0.0,
                    0.0001
                );

            end

        end


        // ========================================================
        // TEST 4
        //
        // GENERAL INPUT
        //
        // x =
        //
        // [1 2 3 4 0 0 0 0]
        //
        // This test exercises:
        //
        // W8^1
        // W8^2
        // W8^3
        //
        // Expected FFT:
        //
        // X0 = 10
        //
        // X1 =
        // -0.41421356 - j7.24264069
        //
        // X2 =
        // -2 + j2
        //
        // X3 =
        // 2.41421356 - j1.24264069
        //
        // X4 =
        // -2
        //
        // X5 =
        // 2.41421356 + j1.24264069
        //
        // X6 =
        // -2 - j2
        //
        // X7 =
        // -0.41421356 + j7.24264069
        // ========================================================

        $display("");
        $display("==============================");
        $display("TEST 4: GENERAL INPUT");
        $display("==============================");


        apply_real_input(
            1,2,3,4,
            0,0,0,0
        );


        wait_for_output();


        check_bin_real(
            0,
            10.0,
            0.0,
            0.001
        );


        check_bin_real(
            1,
            -0.41421356,
            -7.24264069,
            0.001
        );


        check_bin_real(
            2,
            -2.0,
            2.0,
            0.001
        );


        check_bin_real(
            3,
            2.41421356,
            -1.24264069,
            0.001
        );


        check_bin_real(
            4,
            -2.0,
            0.0,
            0.001
        );


        check_bin_real(
            5,
            2.41421356,
            1.24264069,
            0.001
        );


        check_bin_real(
            6,
            -2.0,
            -2.0,
            0.001
        );


        check_bin_real(
            7,
            -0.41421356,
            7.24264069,
            0.001
        );


        $display("");
        $display("------------------------------");
        $display("FULL TEST 4 FFT");
        $display("------------------------------");

        print_fft();

        // ========================================================
        // TEST 5
        // RAMP INPUT
        //
        // x = [1 2 3 4 5 6 7 8]
        // ========================================================

        $display("");
        $display("==============================");
        $display("TEST 5: RAMP INPUT");
        $display("==============================");

        apply_real_input(
            1,2,3,4,
            5,6,7,8
        );

        wait_for_output();

        check_bin_real(0, 36.0,  0.0,        0.001);
        check_bin_real(1, -4.0,  9.65685425, 0.001);
        check_bin_real(2, -4.0,  4.0,        0.001);
        check_bin_real(3, -4.0,  1.65685425, 0.001);
        check_bin_real(4, -4.0,  0.0,        0.001);
        check_bin_real(5, -4.0, -1.65685425, 0.001);
        check_bin_real(6, -4.0, -4.0,        0.001);
        check_bin_real(7, -4.0, -9.65685425, 0.001);

        print_fft();

        // ========================================================
        // TEST 6
        // MIXED POSITIVE / NEGATIVE INPUT
        //
        // x = [3 -1 4 1 5 -9 2 6]
        // ========================================================

        $display("");
        $display("==============================");
        $display("TEST 6: MIXED INPUT");
        $display("==============================");

        apply_real_input(
            3,-1,4,1,
            5,-9,2,6
        );

        wait_for_output();

        check_bin_real(0,  11.0,       0.0,        0.001);
        check_bin_real(1,   7.192388, -4.121320,   0.001);
        check_bin_real(2,   2.0,      17.0,        0.001);
        check_bin_real(3, -11.192388, -0.121320,   0.001);
        check_bin_real(4,  17.0,       0.0,        0.001);
        check_bin_real(5, -11.192388,  0.121320,   0.001);
        check_bin_real(6,   2.0,     -17.0,        0.001);
        check_bin_real(7,   7.192388,  4.121320,   0.001);

        print_fft();


        $display("");
        $display("==============================");
        $display("ALL TESTS COMPLETED");
        $display("==============================");

        // ========================================================
        // TEST 7
        // ASYMMETRIC INPUT
        //
        // x = [2 0 1 -3 4 2 -1 5]
        // ========================================================

        $display("");
        $display("==============================");
        $display("TEST 7: ASYMMETRIC INPUT");
        $display("==============================");

        apply_real_input(
            2,0,1,-3,
            4,2,-1,5
        );

        wait_for_output();

        check_bin_real(0, 10.0,       0.0,       0.001);
        check_bin_real(1,  2.242641,  5.071068,  0.001);
        check_bin_real(2,  6.0,       0.0,       0.001);
        check_bin_real(3, -6.242641,  9.071068,  0.001);
        check_bin_real(4,  2.0,       0.0,       0.001);
        check_bin_real(5, -6.242641, -9.071068,  0.001);
        check_bin_real(6,  6.0,       0.0,       0.001);
        check_bin_real(7,  2.242641, -5.071068,  0.001);

        print_fft();

        #20;

        $finish;

    end

endmodule