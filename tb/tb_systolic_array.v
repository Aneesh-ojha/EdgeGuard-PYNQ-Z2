// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       tb_systolic_array.v
// Description:  Self-checking Testbench for 4x4 Systolic Array.
//               Verifies skewed wavefront timing and matrix multiplication.
// ==============================================================================

`timescale 1ns / 1ps

module tb_systolic_array;

    reg clk;
    reg rst_n;
    reg en;
    reg clr_all;
    reg [1:0] drain_row;

    reg signed [7:0] act_in_0, act_in_1, act_in_2, act_in_3;
    reg signed [7:0] wgt_in_0, wgt_in_1, wgt_in_2, wgt_in_3;

    wire signed [31:0] acc_row_out_0;
    wire signed [31:0] acc_row_out_1;
    wire signed [31:0] acc_row_out_2;
    wire signed [31:0] acc_row_out_3;

    systolic_array_4x4 dut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .clr_all(clr_all),
        .drain_row(drain_row),
        .act_in_0(act_in_0),
        .act_in_1(act_in_1),
        .act_in_2(act_in_2),
        .act_in_3(act_in_3),
        .wgt_in_0(wgt_in_0),
        .wgt_in_1(wgt_in_1),
        .wgt_in_2(wgt_in_2),
        .wgt_in_3(wgt_in_3),
        .acc_row_out_0(acc_row_out_0),
        .acc_row_out_1(acc_row_out_1),
        .acc_row_out_2(acc_row_out_2),
        .acc_row_out_3(acc_row_out_3)
    );

    always #5 clk = ~clk;

    // Test matrices (4x4)
    // A:
    // [ 1,  2,  3,  4 ]
    // [ 2, -1,  1,  0 ]
    // [ 0,  3, -2,  1 ]
    // [ 1,  1,  1,  1 ]
    //
    // B:
    // [  2,  1,  0,  3 ]
    // [  1, -2,  2,  0 ]
    // [ -1,  0,  1,  2 ]
    // [  3,  2, -1,  1 ]

    reg signed [7:0] A [0:3][0:3];
    reg signed [7:0] B [0:3][0:3];
    reg signed [31:0] Gold_C [0:3][0:3];

    integer i, j, k, step;
    integer errors = 0;

    initial begin
        $display("------------------------------------------------------------");
        $display("[TEST] Starting 4x4 Systolic Array Matrix Multiply Test...");
        $display("------------------------------------------------------------");
        
        clk = 0;
        rst_n = 0;
        en = 0;
        clr_all = 0;
        drain_row = 0;
        act_in_0 = 0; act_in_1 = 0; act_in_2 = 0; act_in_3 = 0;
        wgt_in_0 = 0; wgt_in_1 = 0; wgt_in_2 = 0; wgt_in_3 = 0;

        // Initialize test matrices
        A[0][0] = 8'sd1;  A[0][1] = 8'sd2;  A[0][2] = 8'sd3;  A[0][3] = 8'sd4;
        A[1][0] = 8'sd2;  A[1][1] = -8'sd1; A[1][2] = 8'sd1;  A[1][3] = 8'sd0;
        A[2][0] = 8'sd0;  A[2][1] = 8'sd3;  A[2][2] = -8'sd2; A[2][3] = 8'sd1;
        A[3][0] = 8'sd1;  A[3][1] = 8'sd1;  A[3][2] = 8'sd1;  A[3][3] = 8'sd1;

        B[0][0] = 8'sd2;  B[0][1] = 8'sd1;  B[0][2] = 8'sd0;  B[0][3] = 8'sd3;
        B[1][0] = 8'sd1;  B[1][1] = -8'sd2; B[1][2] = 8'sd2;  B[1][3] = 8'sd0;
        B[2][0] = -8'sd1; B[2][1] = 8'sd0;  B[2][2] = 8'sd1;  B[2][3] = 8'sd2;
        B[3][0] = 8'sd3;  B[3][1] = 8'sd2;  B[3][2] = -8'sd1; B[3][3] = 8'sd1;

        // Compute Golden C = A x B
        for (i = 0; i < 4; i = i + 1) begin
            for (j = 0; j < 4; j = j + 1) begin
                Gold_C[i][j] = 0;
                for (k = 0; k < 4; k = k + 1) begin
                    Gold_C[i][j] = Gold_C[i][j] + (A[i][k] * B[k][j]);
                end
            end
        end

        #20;
        rst_n = 1;
        #10;

        // Step 1: Pre-clear all accumulators
        @(posedge clk);
        clr_all = 1;
        @(posedge clk);
        clr_all = 0;

        // Step 2: Stream inputs into array across K=4 time steps
        // At step k, Row i receives A[i][k], Col j receives B[k][j]
        en = 1;
        for (step = 0; step < 4; step = step + 1) begin
            @(posedge clk);
            act_in_0 = A[0][step];
            act_in_1 = A[1][step];
            act_in_2 = A[2][step];
            act_in_3 = A[3][step];

            wgt_in_0 = B[step][0];
            wgt_in_1 = B[step][1];
            wgt_in_2 = B[step][2];
            wgt_in_3 = B[step][3];
        end

        // Step 3: Flush systolic wavefront pipeline (delay 8 cycles with 0 inputs)
        for (step = 0; step < 8; step = step + 1) begin
            @(posedge clk);
            act_in_0 = 0; act_in_1 = 0; act_in_2 = 0; act_in_3 = 0;
            wgt_in_0 = 0; wgt_in_1 = 0; wgt_in_2 = 0; wgt_in_3 = 0;
        end

        @(posedge clk);
        en = 0;
        #1;

        // Step 4: Verify Drained Rows
        for (i = 0; i < 4; i = i + 1) begin
            drain_row = i[1:0];
            #1;
            $display("[CHECK] Row %0d -> HW: [%5d, %5d, %5d, %5d] | GOLD: [%5d, %5d, %5d, %5d]",
                i, acc_row_out_0, acc_row_out_1, acc_row_out_2, acc_row_out_3,
                Gold_C[i][0], Gold_C[i][1], Gold_C[i][2], Gold_C[i][3]);
            
            if (acc_row_out_0 !== Gold_C[i][0] ||
                acc_row_out_1 !== Gold_C[i][1] ||
                acc_row_out_2 !== Gold_C[i][2] ||
                acc_row_out_3 !== Gold_C[i][3]) begin
                $display("[FAIL] Row %0d mismatch!", i);
                errors = errors + 1;
            end
        end

        #20;
        if (errors == 0) begin
            $display("------------------------------------------------------------");
            $display("[SUCCESS] 4x4 Systolic Array Matrix Multiplication PASSED!");
            $display("------------------------------------------------------------");
        end else begin
            $display("------------------------------------------------------------");
            $display("[ERROR] Systolic Array encountered %0d errors!", errors);
            $display("------------------------------------------------------------");
        end
        $finish;
    end

endmodule
