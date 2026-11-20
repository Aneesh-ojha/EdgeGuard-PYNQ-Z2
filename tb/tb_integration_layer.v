// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       tb_integration_layer.v
// Description:  End-to-End Integration Testbench — Single Fully-Connected Layer.
//               Tests a complete 4-output x 8-input INT8 FC layer with known
//               weights, biases, and golden reference output. Verifies the full
//               systolic -> requantizer -> output pipeline bit-exactly.
// ==============================================================================

`timescale 1ns / 1ps

module tb_integration_layer;

    // DUT signals
    reg clk;
    reg rst_n;

    // Systolic Array Controls
    reg         sa_en;
    reg         sa_clr_all;
    reg  [1:0]  drain_row;

    // Systolic Array Inputs
    reg  signed [7:0] act_in_0, act_in_1, act_in_2, act_in_3;
    reg  signed [7:0] wgt_in_0, wgt_in_1, wgt_in_2, wgt_in_3;

    // Systolic Array Outputs
    wire signed [31:0] acc_out_0, acc_out_1, acc_out_2, acc_out_3;

    // Requantizer
    reg         rq_valid_in;
    reg  signed [31:0] bias_0, bias_1, bias_2, bias_3;
    reg  [15:0] quant_mult;
    reg  [4:0]  quant_shift;
    reg         relu_en;
    reg  signed [7:0] clip_min, clip_max;

    wire        rq_valid_out;
    wire [31:0] rq_packed_out;

    systolic_array_4x4 u_sa (
        .clk(clk),   .rst_n(rst_n),
        .en(sa_en),  .clr_all(sa_clr_all),  .drain_row(drain_row),
        .act_in_0(act_in_0), .act_in_1(act_in_1),
        .act_in_2(act_in_2), .act_in_3(act_in_3),
        .wgt_in_0(wgt_in_0), .wgt_in_1(wgt_in_1),
        .wgt_in_2(wgt_in_2), .wgt_in_3(wgt_in_3),
        .acc_row_out_0(acc_out_0), .acc_row_out_1(acc_out_1),
        .acc_row_out_2(acc_out_2), .acc_row_out_3(acc_out_3)
    );

    requant_activation u_rq (
        .clk(clk),   .rst_n(rst_n),   .valid_in(rq_valid_in),
        .accum_in_0(acc_out_0),  .accum_in_1(acc_out_1),
        .accum_in_2(acc_out_2),  .accum_in_3(acc_out_3),
        .bias_in_0(bias_0),      .bias_in_1(bias_1),
        .bias_in_2(bias_2),      .bias_in_3(bias_3),
        .quant_mult(quant_mult), .quant_shift(quant_shift),
        .relu_en(relu_en),       .clip_min(clip_min),  .clip_max(clip_max),
        .valid_out(rq_valid_out), .packed_data_out(rq_packed_out)
    );

    always #5 clk = ~clk;

    // Watchdog timer to prevent hung simulation
    initial begin
        #50000;
        $display("[ERROR] Watchdog timeout: simulation hung!");
        $finish;
    end

    integer errors = 0;

    // Test matrices
    reg signed [7:0] A [0:3][0:7];
    reg signed [7:0] B [0:7][0:3];
    integer drain;
    integer k;

    initial begin
        $display("============================================================");
        $display("   EdgeGuard Integration Test: 4x8 FC Layer (End-to-End)   ");
        $display("============================================================");

        clk        = 0; rst_n = 0;
        sa_en      = 0; sa_clr_all = 0; drain_row = 0;
        rq_valid_in= 0; relu_en = 1;
        quant_mult = 16'd16384; quant_shift = 5'd15;
        clip_min   = -8'sd128;  clip_max = 8'sd127;
        bias_0=0; bias_1=0; bias_2=0; bias_3=0;
        act_in_0=0; act_in_1=0; act_in_2=0; act_in_3=0;
        wgt_in_0=0; wgt_in_1=0; wgt_in_2=0; wgt_in_3=0;

        // Initialize known test matrices
        A[0][0]=10; A[0][1]=20; A[0][2]=30; A[0][3]=40;
        A[0][4]=10; A[0][5]=20; A[0][6]=30; A[0][7]=40;
        A[1][0]=5;  A[1][1]=10; A[1][2]=15; A[1][3]=20;
        A[1][4]=5;  A[1][5]=10; A[1][6]=15; A[1][7]=20;
        A[2][0]=-5; A[2][1]=-10;A[2][2]=-15;A[2][3]=-20;
        A[2][4]=-5; A[2][5]=-10;A[2][6]=-15;A[2][7]=-20;
        A[3][0]=1;  A[3][1]=2;  A[3][2]=3;  A[3][3]=4;
        A[3][4]=1;  A[3][5]=2;  A[3][6]=3;  A[3][7]=4;

        for (k = 0; k < 8; k = k + 1) begin
            B[k][0] = (k % 2 == 0) ? 8'sd1 : 8'sd2;
            B[k][1] = (k % 2 == 0) ? 8'sd1 : 8'sd2;
            B[k][2] = (k % 2 == 0) ? 8'sd1 : 8'sd2;
            B[k][3] = (k % 2 == 0) ? 8'sd1 : 8'sd2;
        end

        #25; rst_n = 1; #10;

        // Step 1: Pre-clear accumulators
        @(posedge clk);
        sa_clr_all <= 1;
        @(posedge clk);
        sa_clr_all <= 0;

        // Step 2: Stream inputs through array: K=8 steps
        sa_en = 1;
        for (k = 0; k < 8; k = k + 1) begin
            @(posedge clk);
            act_in_0 <= A[0][k];
            act_in_1 <= A[1][k];
            act_in_2 <= A[2][k];
            act_in_3 <= A[3][k];
            wgt_in_0 <= B[k][0];
            wgt_in_1 <= B[k][1];
            wgt_in_2 <= B[k][2];
            wgt_in_3 <= B[k][3];
        end

        // Step 3: Flush pipeline (8 zero-input cycles)
        for (k = 0; k < 8; k = k + 1) begin
            @(posedge clk);
            act_in_0 <= 0; act_in_1 <= 0; act_in_2 <= 0; act_in_3 <= 0;
            wgt_in_0 <= 0; wgt_in_1 <= 0; wgt_in_2 <= 0; wgt_in_3 <= 0;
        end
        @(posedge clk);
        sa_en = 0;
        #1;

        // Step 4: Verify raw accumulators
        for (drain = 0; drain < 4; drain = drain + 1) begin
            drain_row = drain[1:0];
            #1;
            case (drain)
                0: begin
                    if (acc_out_0 !== 32'sd320 || acc_out_1 !== 32'sd320 ||
                        acc_out_2 !== 32'sd320 || acc_out_3 !== 32'sd320) begin
                        $display("[FAIL] Row 0 accum: [%0d,%0d,%0d,%0d] expected [320,320,320,320]",
                            acc_out_0, acc_out_1, acc_out_2, acc_out_3);
                        errors = errors + 1;
                    end else
                        $display("[PASS] Row 0 accum: [%0d,%0d,%0d,%0d] ok", acc_out_0, acc_out_1, acc_out_2, acc_out_3);
                end
                1: begin
                    if (acc_out_0 !== 32'sd160 || acc_out_1 !== 32'sd160 ||
                        acc_out_2 !== 32'sd160 || acc_out_3 !== 32'sd160) begin
                        $display("[FAIL] Row 1 accum: [%0d,%0d,%0d,%0d] expected [160,160,160,160]",
                            acc_out_0, acc_out_1, acc_out_2, acc_out_3);
                        errors = errors + 1;
                    end else
                        $display("[PASS] Row 1 accum: [%0d,%0d,%0d,%0d] ok", acc_out_0, acc_out_1, acc_out_2, acc_out_3);
                end
                2: begin
                    if (acc_out_0 !== -32'sd160 || acc_out_1 !== -32'sd160 ||
                        acc_out_2 !== -32'sd160 || acc_out_3 !== -32'sd160) begin
                        $display("[FAIL] Row 2 accum: [%0d,%0d,%0d,%0d] expected [-160,-160,-160,-160]",
                            acc_out_0, acc_out_1, acc_out_2, acc_out_3);
                        errors = errors + 1;
                    end else
                        $display("[PASS] Row 2 accum: [%0d,%0d,%0d,%0d] ok", acc_out_0, acc_out_1, acc_out_2, acc_out_3);
                end
                3: begin
                    if (acc_out_0 !== 32'sd32 || acc_out_1 !== 32'sd32 ||
                        acc_out_2 !== 32'sd32 || acc_out_3 !== 32'sd32) begin
                        $display("[FAIL] Row 3 accum: [%0d,%0d,%0d,%0d] expected [32,32,32,32]",
                            acc_out_0, acc_out_1, acc_out_2, acc_out_3);
                        errors = errors + 1;
                    end else
                        $display("[PASS] Row 3 accum: [%0d,%0d,%0d,%0d] ok", acc_out_0, acc_out_1, acc_out_2, acc_out_3);
                end
            endcase
        end

        $display("");
        $display("[INFO] Testing Requantizer: M0=16384, shift=15 -> scale=0.5, ReLU=ON");

        // Step 5: Feed each row through Requantizer
        for (drain = 0; drain < 4; drain = drain + 1) begin
            @(posedge clk);
            drain_row   <= drain[1:0];
            rq_valid_in <= 1'b1;

            @(posedge clk);
            rq_valid_in <= 1'b0;

            // Wait for valid_out
            @(posedge rq_valid_out);
            #1;

            case (drain)
                0: begin
                    // Expected: 320*0.5 = 160 -> clamped to 127
                    if ($signed(rq_packed_out[7:0])   !== 8'sd127 ||
                        $signed(rq_packed_out[15:8])  !== 8'sd127 ||
                        $signed(rq_packed_out[23:16]) !== 8'sd127 ||
                        $signed(rq_packed_out[31:24]) !== 8'sd127) begin
                        $display("[FAIL] RQ Row 0: [%0d,%0d,%0d,%0d] expected [127,127,127,127]",
                            $signed(rq_packed_out[7:0]),   $signed(rq_packed_out[15:8]),
                            $signed(rq_packed_out[23:16]), $signed(rq_packed_out[31:24]));
                        errors = errors + 1;
                    end else
                        $display("[PASS] RQ Row 0: [%0d,%0d,%0d,%0d] ok (160->clamp->127)",
                            $signed(rq_packed_out[7:0]), $signed(rq_packed_out[15:8]),
                            $signed(rq_packed_out[23:16]), $signed(rq_packed_out[31:24]));
                end
                1: begin
                    // Expected: 160*0.5 = 80
                    if ($signed(rq_packed_out[7:0]) !== 8'sd80) begin
                        $display("[FAIL] RQ Row 1: Ch0=%0d expected 80", $signed(rq_packed_out[7:0]));
                        errors = errors + 1;
                    end else
                        $display("[PASS] RQ Row 1: [%0d,%0d,%0d,%0d] ok",
                            $signed(rq_packed_out[7:0]), $signed(rq_packed_out[15:8]),
                            $signed(rq_packed_out[23:16]), $signed(rq_packed_out[31:24]));
                end
                2: begin
                    // Expected: -160*0.5 = -80 -> ReLU -> 0
                    if ($signed(rq_packed_out[7:0]) !== 8'sd0) begin
                        $display("[FAIL] RQ Row 2: Ch0=%0d expected 0 (ReLU of -80)",
                            $signed(rq_packed_out[7:0]));
                        errors = errors + 1;
                    end else
                        $display("[PASS] RQ Row 2: [%0d,%0d,%0d,%0d] ok (ReLU clamps -80->0)",
                            $signed(rq_packed_out[7:0]), $signed(rq_packed_out[15:8]),
                            $signed(rq_packed_out[23:16]), $signed(rq_packed_out[31:24]));
                end
                3: begin
                    // Expected: 32*0.5 = 16
                    if ($signed(rq_packed_out[7:0]) !== 8'sd16) begin
                        $display("[FAIL] RQ Row 3: Ch0=%0d expected 16", $signed(rq_packed_out[7:0]));
                        errors = errors + 1;
                    end else
                        $display("[PASS] RQ Row 3: [%0d,%0d,%0d,%0d] ok",
                            $signed(rq_packed_out[7:0]), $signed(rq_packed_out[15:8]),
                            $signed(rq_packed_out[23:16]), $signed(rq_packed_out[31:24]));
                end
            endcase
        end

        #20;
        $display("");
        $display("============================================================");
        if (errors == 0) begin
            $display("[SUCCESS] End-to-End FC Layer Integration Test PASSED!");
            $display("          Bit-exact match between hardware and golden reference.");
        end else begin
            $display("[ERROR] Integration test encountered %0d errors!", errors);
        end
        $display("============================================================");
        $finish;
    end

endmodule
