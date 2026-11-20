// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       bram_dp.v
// Description:  Synthesizable Dual-Port RAM inferred as Xilinx 7-Series Block RAM.
//               Port A: Write / Read (System/DMA/FSM)
//               Port B: Read Only (Systolic Array Core)
// Target FPGA:  Xilinx Zynq-7020 (XC7Z020-1CLG400C) / PYNQ-Z2
// Standard:     Synthesizable Verilog-2001
// ==============================================================================

`timescale 1ns / 1ps

module bram_dp #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 10,  // 1024 words default
    parameter DEPTH      = (1 << ADDR_WIDTH)
)(
    input  wire                   clk,
    
    // Port A (Write / Read)
    input  wire                   we_a,
    input  wire [ADDR_WIDTH-1:0]  addr_a,
    input  wire [DATA_WIDTH-1:0]  din_a,
    output reg  [DATA_WIDTH-1:0]  dout_a,
    
    // Port B (Read Only)
    input  wire                   en_b,
    input  wire [ADDR_WIDTH-1:0]  addr_b,
    output reg  [DATA_WIDTH-1:0]  dout_b
);

    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];

    // Power-on default initialization (matches FPGA BRAM power-on reset state)
    integer init_idx;
    initial begin
        for (init_idx = 0; init_idx < DEPTH; init_idx = init_idx + 1) begin
            ram[init_idx] = {DATA_WIDTH{1'b0}};
        end
    end

    // Port A
    always @(posedge clk) begin
        if (we_a) begin
            ram[addr_a] <= din_a;
        end
        dout_a <= ram[addr_a];
    end

    // Port B
    always @(posedge clk) begin
        if (en_b) begin
            dout_b <= ram[addr_b];
        end
    end

endmodule
