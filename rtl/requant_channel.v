// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       requant_channel.v
// Description:  Single-channel INT32-to-INT8 Requantization and Activation Unit.
//               Implements: Y = Clip(ReLU((Accum + Bias) * M0 >> n), Min, Max)
//               3-stage fully-registered pipeline for timing closure at 100+ MHz.
// Target FPGA:  Xilinx Zynq-7020 (XC7Z020-1CLG400C) / PYNQ-Z2
// Standard:     Synthesizable Verilog-2001
// Revision:     1.1 — Fixed Bug 3: round_offset registered in Stage 2 to avoid
//               combinatorial underflow when shift=0.
// ==============================================================================

`timescale 1ns / 1ps

module requant_channel #(
    parameter ACC_WIDTH   = 32,
    parameter BIAS_WIDTH  = 32,
    parameter MULT_WIDTH  = 16,
    parameter OUT_WIDTH   = 8
)(
    input  wire                           clk,
    input  wire                           rst_n,
    input  wire                           valid_in,

    // Data Inputs
    input  wire signed [ACC_WIDTH-1:0]    accum_in,
    input  wire signed [BIAS_WIDTH-1:0]   bias_in,

    // Scale Parameters (registered internally — stable across pipeline)
    input  wire [MULT_WIDTH-1:0]          quant_mult,  // Fixed-point scale M0 (unsigned)
    input  wire [4:0]                     quant_shift, // Right shift n (0..31)
    input  wire                           relu_en,     // 1: ReLU, 0: Linear
    input  wire signed [OUT_WIDTH-1:0]    clip_min,    // Clamp minimum (-128 or 0)
    input  wire signed [OUT_WIDTH-1:0]    clip_max,    // Clamp maximum (127)

    // Quantized Output
    output reg                            valid_out,
    output reg  signed [OUT_WIDTH-1:0]    data_out
);

    // -------------------------------------------------------------------------
    // Pipeline Stage 1: Bias Addition (33-bit to prevent overflow)
    // -------------------------------------------------------------------------
    reg                             v1;
    reg  signed [ACC_WIDTH:0]       sum_bias;   // 33-bit signed
    reg  [MULT_WIDTH-1:0]           mult_r1;
    reg  [4:0]                      shift_r1;
    reg                             relu_r1;
    reg  signed [OUT_WIDTH-1:0]     min_r1, max_r1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1       <= 1'b0;
            sum_bias <= {(ACC_WIDTH+1){1'b0}};
            mult_r1  <= {MULT_WIDTH{1'b0}};
            shift_r1 <= 5'd0;
            relu_r1  <= 1'b0;
            min_r1   <= {OUT_WIDTH{1'b0}};
            max_r1   <= {OUT_WIDTH{1'b0}};
        end else begin
            v1       <= valid_in;
            sum_bias <= $signed({{1{accum_in[ACC_WIDTH-1]}}, accum_in}) +
                        $signed({{1{bias_in[BIAS_WIDTH-1]}}, bias_in});
            mult_r1  <= quant_mult;
            shift_r1 <= quant_shift;
            relu_r1  <= relu_en;
            min_r1   <= clip_min;
            max_r1   <= clip_max;
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 2: Fixed-Point Multiplier + Registered Round Offset
    // FIX (v1.1): round_offset computed and registered here to avoid
    // combinatorial shift-by-(shift_r2-1) when shift_r2=0 (underflows to 31).
    // -------------------------------------------------------------------------
    reg                             v2;
    reg  signed [48:0]              product;      // 33-bit × 16-bit = 49-bit
    reg  signed [48:0]              round_offset; // Registered half-LSB offset
    reg  [4:0]                      shift_r2;
    reg                             relu_r2;
    reg  signed [OUT_WIDTH-1:0]     min_r2, max_r2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v2           <= 1'b0;
            product      <= 49'sd0;
            round_offset <= 49'sd0;
            shift_r2     <= 5'd0;
            relu_r2      <= 1'b0;
            min_r2       <= {OUT_WIDTH{1'b0}};
            max_r2       <= {OUT_WIDTH{1'b0}};
        end else begin
            v2       <= v1;
            // Signed × unsigned (M0 is always positive scale factor)
            product  <= sum_bias * $signed({1'b0, mult_r1});
            // FIX: registered round offset — safe against shift_r1 == 0 underflow
            round_offset <= (shift_r1 > 5'd0) ? ($signed(49'd1) << (shift_r1 - 5'd1)) : 49'sd0;
            shift_r2     <= shift_r1;
            relu_r2      <= relu_r1;
            min_r2       <= min_r1;
            max_r2       <= max_r1;
        end
    end

    // -------------------------------------------------------------------------
    // Pipeline Stage 3: Rounding, Arithmetic Shift, ReLU, Saturation Clamp
    // -------------------------------------------------------------------------
    wire signed [48:0] rounded_val;
    assign rounded_val = product + round_offset;

    wire signed [31:0] shifted_val;
    assign shifted_val = rounded_val >>> shift_r2;

    wire signed [31:0] activated_val;
    assign activated_val = (relu_r2 && shifted_val[31]) ? 32'sd0 : shifted_val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            data_out  <= {OUT_WIDTH{1'b0}};
        end else begin
            valid_out <= v2;
            if (v2) begin
                // Saturation clamp — using sign-extended min/max for comparison
                if (activated_val > $signed({{24{max_r2[OUT_WIDTH-1]}}, max_r2}))
                    data_out <= max_r2;
                else if (activated_val < $signed({{24{min_r2[OUT_WIDTH-1]}}, min_r2}))
                    data_out <= min_r2;
                else
                    data_out <= activated_val[OUT_WIDTH-1:0];
            end
        end
    end

endmodule
