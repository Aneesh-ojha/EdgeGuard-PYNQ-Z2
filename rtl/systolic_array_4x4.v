// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       systolic_array_4x4.v
// Description:  4×4 2D Systolic Array Compute Core for INT8 GEMM.
//               Features:
//               - Diagonal input skewing registers for wavefront timing
//               - Independent clr_all pulse to zero all 16 accumulators
//               - 16 parallel PEs, each mapping to one DSP48E1
//               - Row-multiplexed INT32 output readout
// Target FPGA:  Xilinx Zynq-7020 (XC7Z020-1CLG400C) / PYNQ-Z2
// Standard:     Synthesizable Verilog-2001
// Revision:     1.1 — Fixed .en logic (Bug 2): clr_all no longer gates PE en.
//               Clear is handled exclusively via clr_acc path in systolic_pe.
// ==============================================================================

`timescale 1ns / 1ps

module systolic_array_4x4 #(
    parameter ARRAY_SIZE = 4,    // NxN array size (4×4 = 16 PEs)
    parameter ACT_WIDTH  = 8,
    parameter WGT_WIDTH  = 8,
    parameter ACC_WIDTH  = 32
)(
    input  wire                               clk,
    input  wire                               rst_n,

    // Control
    input  wire                               en,         // Global compute enable
    input  wire                               clr_all,    // Synchronous clear all accumulators (independent of en)
    input  wire [1:0]                         drain_row,  // Output row selector (0..3)

    // External Data Inputs (unskewed — FSM drives all rows/cols simultaneously)
    input  wire signed [ACT_WIDTH-1:0]        act_in_0,
    input  wire signed [ACT_WIDTH-1:0]        act_in_1,
    input  wire signed [ACT_WIDTH-1:0]        act_in_2,
    input  wire signed [ACT_WIDTH-1:0]        act_in_3,

    input  wire signed [WGT_WIDTH-1:0]        wgt_in_0,
    input  wire signed [WGT_WIDTH-1:0]        wgt_in_1,
    input  wire signed [WGT_WIDTH-1:0]        wgt_in_2,
    input  wire signed [WGT_WIDTH-1:0]        wgt_in_3,

    // Drained Row Outputs (4 INT32 accumulators from selected row)
    output wire signed [ACC_WIDTH-1:0]        acc_row_out_0,
    output wire signed [ACC_WIDTH-1:0]        acc_row_out_1,
    output wire signed [ACC_WIDTH-1:0]        acc_row_out_2,
    output wire signed [ACC_WIDTH-1:0]        acc_row_out_3
);

    // -------------------------------------------------------------------------
    // 1. Input Skewing Registers
    //    Row i receives its activation i cycles late.
    //    Col j receives its weight j cycles late.
    //    This ensures PE(i,j) multiplies A[i][k] × B[k][j] on the same cycle.
    // -------------------------------------------------------------------------
    wire signed [ACT_WIDTH-1:0] act_skewed [0:3];
    reg  signed [ACT_WIDTH-1:0] act_d1, act_d2_0, act_d2_1, act_d3_0, act_d3_1, act_d3_2;

    assign act_skewed[0] = act_in_0;
    assign act_skewed[1] = act_d1;
    assign act_skewed[2] = act_d2_1;
    assign act_skewed[3] = act_d3_2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_d1   <= {ACT_WIDTH{1'b0}};
            act_d2_0 <= {ACT_WIDTH{1'b0}};
            act_d2_1 <= {ACT_WIDTH{1'b0}};
            act_d3_0 <= {ACT_WIDTH{1'b0}};
            act_d3_1 <= {ACT_WIDTH{1'b0}};
            act_d3_2 <= {ACT_WIDTH{1'b0}};
        end else if (en) begin
            act_d1   <= act_in_1;
            act_d2_0 <= act_in_2;
            act_d2_1 <= act_d2_0;
            act_d3_0 <= act_in_3;
            act_d3_1 <= act_d3_0;
            act_d3_2 <= act_d3_1;
        end
    end

    wire signed [WGT_WIDTH-1:0] wgt_skewed [0:3];
    reg  signed [WGT_WIDTH-1:0] wgt_d1, wgt_d2_0, wgt_d2_1, wgt_d3_0, wgt_d3_1, wgt_d3_2;

    assign wgt_skewed[0] = wgt_in_0;
    assign wgt_skewed[1] = wgt_d1;
    assign wgt_skewed[2] = wgt_d2_1;
    assign wgt_skewed[3] = wgt_d3_2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wgt_d1   <= {WGT_WIDTH{1'b0}};
            wgt_d2_0 <= {WGT_WIDTH{1'b0}};
            wgt_d2_1 <= {WGT_WIDTH{1'b0}};
            wgt_d3_0 <= {WGT_WIDTH{1'b0}};
            wgt_d3_1 <= {WGT_WIDTH{1'b0}};
            wgt_d3_2 <= {WGT_WIDTH{1'b0}};
        end else if (en) begin
            wgt_d1   <= wgt_in_1;
            wgt_d2_0 <= wgt_in_2;
            wgt_d2_1 <= wgt_d2_0;
            wgt_d3_0 <= wgt_in_3;
            wgt_d3_1 <= wgt_d3_0;
            wgt_d3_2 <= wgt_d3_1;
        end
    end

    // -------------------------------------------------------------------------
    // 2. 4×4 Grid Interconnect Wires
    // -------------------------------------------------------------------------
    wire signed [ACT_WIDTH-1:0] h_wire [0:3][0:4]; // h_wire[row][0] = skewed input
    wire signed [WGT_WIDTH-1:0] v_wire [0:4][0:3]; // v_wire[0][col] = skewed input
    wire signed [ACC_WIDTH-1:0] pe_accum [0:3][0:3];

    genvar b;
    generate
        for (b = 0; b < 4; b = b + 1) begin : gen_boundaries
            assign h_wire[b][0] = act_skewed[b];
            assign v_wire[0][b] = wgt_skewed[b];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 3. PE Matrix Instantiation
    //    FIX (v1.1): .en(en) only — clr_acc handled separately via clr_all.
    //    This ensures clear happens cleanly without stale product corruption.
    // -------------------------------------------------------------------------
    genvar r, c;
    generate
        for (r = 0; r < 4; r = r + 1) begin : gen_row
            for (c = 0; c < 4; c = c + 1) begin : gen_col
                systolic_pe #(
                    .ACT_WIDTH(ACT_WIDTH),
                    .WGT_WIDTH(WGT_WIDTH),
                    .ACC_WIDTH(ACC_WIDTH)
                ) u_pe (
                    .clk     (clk),
                    .rst_n   (rst_n),
                    .en      (en),         // FIX: en and clr_acc are now independent
                    .clr_acc (clr_all),    // FIX: clear fires even when en=0
                    .in_a    (h_wire[r][c]),
                    .in_b    (v_wire[r][c]),
                    .out_a   (h_wire[r][c+1]),
                    .out_b   (v_wire[r+1][c]),
                    .accum_out(pe_accum[r][c])
                );
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 4. Output Row Readout Multiplexer
    // -------------------------------------------------------------------------
    assign acc_row_out_0 = pe_accum[drain_row][0];
    assign acc_row_out_1 = pe_accum[drain_row][1];
    assign acc_row_out_2 = pe_accum[drain_row][2];
    assign acc_row_out_3 = pe_accum[drain_row][3];

endmodule
