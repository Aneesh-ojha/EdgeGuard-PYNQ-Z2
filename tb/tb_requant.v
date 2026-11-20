// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       tb_requant.v
// Description:  Self-checking Testbench for 4-Channel Requantizer and ReLU Unit.
// ==============================================================================

`timescale 1ns / 1ps

module tb_requant;

    reg clk;
    reg rst_n;
    reg valid_in;

    reg signed [31:0] accum_in_0, accum_in_1, accum_in_2, accum_in_3;
    reg signed [31:0] bias_in_0, bias_in_1, bias_in_2, bias_in_3;
    reg [15:0]        quant_mult;
    reg [4:0]         quant_shift;
    reg               relu_en;
    reg signed [7:0]  clip_min;
    reg signed [7:0]  clip_max;

    wire        valid_out;
    wire [31:0] packed_data_out;

    requant_activation dut (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .accum_in_0(accum_in_0),
        .accum_in_1(accum_in_1),
        .accum_in_2(accum_in_2),
        .accum_in_3(accum_in_3),
        .bias_in_0(bias_in_0),
        .bias_in_1(bias_in_1),
        .bias_in_2(bias_in_2),
        .bias_in_3(bias_in_3),
        .quant_mult(quant_mult),
        .quant_shift(quant_shift),
        .relu_en(relu_en),
        .clip_min(clip_min),
        .clip_max(clip_max),
        .valid_out(valid_out),
        .packed_data_out(packed_data_out)
    );

    always #5 clk = ~clk;

    integer errors = 0;

    initial begin
        $display("------------------------------------------------------------");
        $display("[TEST] Starting 4-Channel Requantizer Unit Testbench...");
        $display("------------------------------------------------------------");
        
        clk = 0;
        rst_n = 0;
        valid_in = 0;
        accum_in_0 = 0; accum_in_1 = 0; accum_in_2 = 0; accum_in_3 = 0;
        bias_in_0 = 0; bias_in_1 = 0; bias_in_2 = 0; bias_in_3 = 0;
        quant_mult = 16'd16384; // 0.5 in Q15
        quant_shift = 5'd15;
        relu_en = 1;
        clip_min = -8'sd128;
        clip_max = 8'sd127;

        #20;
        rst_n = 1;
        #10;

        // Test 1: Standard scaling with ReLU
        // Channel 0: accum = 100, bias = 0  -> (100 * 16384 + 16384) >> 15 = 50
        // Channel 1: accum = -50, bias = 10 -> -40 -> with ReLU = 0
        // Channel 2: accum = 500, bias = 0  -> 250 -> clipped to 127
        // Channel 3: accum = 20, bias = 4   -> 24 -> 12
        @(posedge clk);
        valid_in   = 1;
        accum_in_0 = 32'sd100; bias_in_0 = 32'sd0;
        accum_in_1 = -32'sd50; bias_in_1 = 32'sd10;
        accum_in_2 = 32'sd500; bias_in_2 = 32'sd0;
        accum_in_3 = 32'sd20;  bias_in_3 = 32'sd4;

        @(posedge clk);
        valid_in = 0;

        // Wait for valid_out
        @(posedge valid_out);
        #1;

        $display("[CHECK] Ch0: %d (exp 50), Ch1: %d (exp 0), Ch2: %d (exp 127), Ch3: %d (exp 12)",
            $signed(packed_data_out[7:0]),
            $signed(packed_data_out[15:8]),
            $signed(packed_data_out[23:16]),
            $signed(packed_data_out[31:24]));
        
        if ($signed(packed_data_out[7:0]) !== 8'sd50 ||
            $signed(packed_data_out[15:8]) !== 8'sd0 ||
            $signed(packed_data_out[23:16]) !== 8'sd127 ||
            $signed(packed_data_out[31:24]) !== 8'sd12) begin
            $display("[FAIL] Requantizer output mismatch!");
            errors = errors + 1;
        end else begin
            $display("[PASS] Requantization, ReLU, and Clamping verified!");
        end

        #20;
        if (errors == 0) begin
            $display("------------------------------------------------------------");
            $display("[SUCCESS] All Requantizer tests PASSED!");
            $display("------------------------------------------------------------");
        end else begin
            $display("------------------------------------------------------------");
            $display("[ERROR] Requantizer encountered %0d errors!", errors);
            $display("------------------------------------------------------------");
        end
        $finish;
    end

endmodule
