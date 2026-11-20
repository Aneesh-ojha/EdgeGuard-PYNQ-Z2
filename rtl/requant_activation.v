// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       requant_activation.v
// Description:  4-Channel Parallel INT32 to INT8 Requantizer with Output Packing.
//               Converts 4 x INT32 accumulators to 4 x INT8 quantized values,
//               packing them directly into a 32-bit word for AXI-Stream.
// Target FPGA:  Xilinx Zynq-7020 (XC7Z020-1CLG400C) / PYNQ-Z2
// Standard:     Synthesizable Verilog-2001
// ==============================================================================

`timescale 1ns / 1ps

module requant_activation (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 valid_in,
    
    // 4 Accumulator inputs from systolic row
    input  wire signed [31:0]   accum_in_0,
    input  wire signed [31:0]   accum_in_1,
    input  wire signed [31:0]   accum_in_2,
    input  wire signed [31:0]   accum_in_3,
    
    // 4 Bias inputs
    input  wire signed [31:0]   bias_in_0,
    input  wire signed [31:0]   bias_in_1,
    input  wire signed [31:0]   bias_in_2,
    input  wire signed [31:0]   bias_in_3,
    
    // Quantization Parameters
    input  wire [15:0]          quant_mult,
    input  wire [4:0]           quant_shift,
    input  wire                 relu_en,
    input  wire signed [7:0]    clip_min,
    input  wire signed [7:0]    clip_max,
    
    // Packed 32-bit Output (4 x INT8)
    output wire                 valid_out,
    output wire [31:0]          packed_data_out
);

    wire        ch_valid [0:3];
    wire [7:0]  ch_data  [0:3];

    requant_channel u_ch0 (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in),
        .accum_in(accum_in_0), .bias_in(bias_in_0),
        .quant_mult(quant_mult), .quant_shift(quant_shift),
        .relu_en(relu_en), .clip_min(clip_min), .clip_max(clip_max),
        .valid_out(ch_valid[0]), .data_out(ch_data[0])
    );

    requant_channel u_ch1 (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in),
        .accum_in(accum_in_1), .bias_in(bias_in_1),
        .quant_mult(quant_mult), .quant_shift(quant_shift),
        .relu_en(relu_en), .clip_min(clip_min), .clip_max(clip_max),
        .valid_out(ch_valid[1]), .data_out(ch_data[1])
    );

    requant_channel u_ch2 (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in),
        .accum_in(accum_in_2), .bias_in(bias_in_2),
        .quant_mult(quant_mult), .quant_shift(quant_shift),
        .relu_en(relu_en), .clip_min(clip_min), .clip_max(clip_max),
        .valid_out(ch_valid[2]), .data_out(ch_data[2])
    );

    requant_channel u_ch3 (
        .clk(clk), .rst_n(rst_n), .valid_in(valid_in),
        .accum_in(accum_in_3), .bias_in(bias_in_3),
        .quant_mult(quant_mult), .quant_shift(quant_shift),
        .relu_en(relu_en), .clip_min(clip_min), .clip_max(clip_max),
        .valid_out(ch_valid[3]), .data_out(ch_data[3])
    );

    // Outputs are synchronized across all 4 channels
    assign valid_out       = ch_valid[0];
    assign packed_data_out = {ch_data[3], ch_data[2], ch_data[1], ch_data[0]};

endmodule
