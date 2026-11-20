// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       tb_systolic_pe.v
// Description:  Self-checking Unit Testbench for Systolic Processing Element.
// ==============================================================================

`timescale 1ns / 1ps

module tb_systolic_pe;

    reg clk;
    reg rst_n;
    reg en;
    reg clr_acc;
    reg signed [7:0] in_a;
    reg signed [7:0] in_b;

    wire signed [7:0]  out_a;
    wire signed [7:0]  out_b;
    wire signed [31:0] accum_out;

    systolic_pe #(
        .ACT_WIDTH(8),
        .WGT_WIDTH(8),
        .ACC_WIDTH(32)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .clr_acc(clr_acc),
        .in_a(in_a),
        .in_b(in_b),
        .out_a(out_a),
        .out_b(out_b),
        .accum_out(accum_out)
    );

    // Clock generation (100 MHz -> 10ns period)
    always #5 clk = ~clk;

    integer errors = 0;

    initial begin
        $display("------------------------------------------------------------");
        $display("[TEST] Starting Systolic PE Unit Testbench...");
        $display("------------------------------------------------------------");
        
        clk = 0;
        rst_n = 0;
        en = 0;
        clr_acc = 0;
        in_a = 0;
        in_b = 0;

        #20;
        rst_n = 1;
        #10;

        // Test 1: Single clear & MAC (3 * 4 = 12)
        @(posedge clk);
        en = 1;
        clr_acc = 1;
        in_a = 8'sd3;
        in_b = 8'sd4;

        @(posedge clk);
        clr_acc = 0;
        in_a = 8'sd5;
        in_b = -8'sd2; // 12 + (5 * -2) = 2

        @(posedge clk);
        in_a = 8'sd10;
        in_b = 8'sd10; // 2 + 100 = 102

        @(posedge clk);
        en = 0;
        #1;
        if (accum_out !== 32'sd102) begin
            $display("[FAIL] Expected 102, got %d", accum_out);
            errors = errors + 1;
        end else begin
            $display("[PASS] Positive & negative MAC accumulated correctly: %d", accum_out);
        end

        // Test 2: Extreme corner case (-128 * 127)
        @(posedge clk);
        en = 1;
        clr_acc = 1;
        in_a = -8'sd128;
        in_b = 8'sd127; // -16256

        @(posedge clk);
        en = 0;
        #1;
        if (accum_out !== -32'sd16256) begin
            $display("[FAIL] Extreme signed multiply failed. Expected -16256, got %d", accum_out);
            errors = errors + 1;
        end else begin
            $display("[PASS] Corner case (-128 * 127) passed: %d", accum_out);
        end

        // Test 3: Wavefront forwarding
        @(posedge clk);
        en = 1;
        in_a = 8'sd42;
        in_b = 8'sd84;
        @(posedge clk);
        #1;
        if (out_a !== 8'sd42 || out_b !== 8'sd84) begin
            $display("[FAIL] Forwarding register failed: out_a=%d, out_b=%d", out_a, out_b);
            errors = errors + 1;
        end else begin
            $display("[PASS] Systolic operand forwarding verified (out_a=%d, out_b=%d)", out_a, out_b);
        end

        #20;
        if (errors == 0) begin
            $display("------------------------------------------------------------");
            $display("[SUCCESS] All Systolic PE tests PASSED!");
            $display("------------------------------------------------------------");
        end else begin
            $display("------------------------------------------------------------");
            $display("[ERROR] Systolic PE tests encountered %0d errors!", errors);
            $display("------------------------------------------------------------");
        end
        $finish;
    end

endmodule
