// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       axi_lite_regs.v
// Description:  AXI4-Lite Slave Interface for Configuration, Control, Status,
//               and Hardware Performance Profiling.
//               Fully compliant with AMBA AXI4-Lite Protocol Specification.
// Target FPGA:  Xilinx Zynq-7020 (XC7Z020-1CLG400C) / PYNQ-Z2
// Standard:     AMBA AXI4-Lite Protocol Compliant
// ==============================================================================

`timescale 1ns / 1ps

module axi_lite_regs #(
    parameter ADDR_WIDTH = 8,
    parameter DATA_WIDTH = 32
)(
    input  wire                   aclk,
    input  wire                   aresetn,

    // AXI4-Lite Write Address Channel
    input  wire [ADDR_WIDTH-1:0]  s_axi_awaddr,
    input  wire                   s_axi_awvalid,
    output reg                    s_axi_awready,

    // AXI4-Lite Write Data Channel
    input  wire [DATA_WIDTH-1:0]  s_axi_wdata,
    input  wire [3:0]             s_axi_wstrb,
    input  wire                   s_axi_wvalid,
    output reg                    s_axi_wready,

    // AXI4-Lite Write Response Channel
    output reg  [1:0]             s_axi_bresp,
    output reg                    s_axi_bvalid,
    input  wire                   s_axi_bready,

    // AXI4-Lite Read Address Channel
    input  wire [ADDR_WIDTH-1:0]  s_axi_araddr,
    input  wire                   s_axi_arvalid,
    output reg                    s_axi_arready,

    // AXI4-Lite Read Data Channel
    output reg  [DATA_WIDTH-1:0]  s_axi_rdata,
    output reg  [1:0]             s_axi_rresp,
    output reg                    s_axi_rvalid,
    input  wire                   s_axi_rready,

    // Core Control & Configuration Outputs
    output reg                    ctrl_start,
    output reg                    ctrl_soft_rst,
    output reg  [15:0]            cfg_dim_m,
    output reg  [15:0]            cfg_dim_k,
    output reg  [15:0]            cfg_dim_n,
    output reg  [15:0]            cfg_quant_scale,
    output reg  [4:0]             cfg_quant_shift,
    output reg                    cfg_relu_en,
    output reg  signed [7:0]      cfg_clip_min,
    output reg  signed [7:0]      cfg_clip_max,

    // Core Status Inputs
    input  wire                   status_busy,
    input  wire                   status_done,
    input  wire [7:0]             status_fsm_state,
    input  wire [31:0]            perf_cycle_count,
    output reg                    irq_out
);

    // Register Address Map
    localparam ADDR_CTRL         = 8'h00; // R/W: bit0=start, bit1=soft_rst, bit2=irq_en, bit3=clr_done
    localparam ADDR_STATUS       = 8'h04; // RO:  bit0=busy, bit1=done, [23:16]=fsm_state
    localparam ADDR_DIM_M        = 8'h08; // R/W: Matrix M (rows / batch)
    localparam ADDR_DIM_K        = 8'h0C; // R/W: Matrix K (inner dimension)
    localparam ADDR_DIM_N        = 8'h10; // R/W: Matrix N (output neurons)
    localparam ADDR_QUANT_SCALE  = 8'h14; // R/W: M0 fixed-point multiplier [15:0]
    localparam ADDR_QUANT_SHIFT  = 8'h18; // R/W: Shift amount n [4:0]
    localparam ADDR_LAYER_CFG    = 8'h1C; // R/W: [0]=relu_en, [15:8]=clip_min, [23:16]=clip_max
    localparam ADDR_PERF_CYCLES  = 8'h20; // RO:  32-bit clock cycle counter
    localparam ADDR_IRQ_CFG      = 8'h24; // R/W: [0]=irq_enable
    localparam ADDR_IP_ID        = 8'h28; // RO:  0x45470000 ("EG")
    localparam ADDR_IP_VERSION   = 8'h2C; // RO:  0x01010000 (v1.1)

    localparam IP_ID      = 32'h4547_0000;
    localparam IP_VERSION = 32'h0101_0000;

    reg        irq_enable;
    reg        clear_done_reg;

    // -------------------------------------------------------------------------
    // AXI4-Lite Write Channel
    // -------------------------------------------------------------------------
    reg [ADDR_WIDTH-1:0] awaddr_lat;
    reg [DATA_WIDTH-1:0] wdata_lat;
    reg [3:0]            wstrb_lat;
    reg                  aw_latched;
    reg                  w_latched;

    wire [ADDR_WIDTH-1:0] effective_addr = aw_latched ? awaddr_lat : s_axi_awaddr;
    wire [DATA_WIDTH-1:0] effective_data = w_latched  ? wdata_lat  : s_axi_wdata;
    wire [3:0]            effective_strb = w_latched  ? wstrb_lat  : s_axi_wstrb;

    wire wr_en = (!s_axi_bvalid) &&
                 (s_axi_awvalid || aw_latched) &&
                 (s_axi_wvalid  || w_latched);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axi_awready  <= 1'b0;
            s_axi_wready   <= 1'b0;
            s_axi_bvalid   <= 1'b0;
            s_axi_bresp    <= 2'b00;
            aw_latched     <= 1'b0;
            w_latched      <= 1'b0;
            awaddr_lat     <= {ADDR_WIDTH{1'b0}};
            wdata_lat      <= {DATA_WIDTH{1'b0}};
            wstrb_lat      <= 4'b0;

            ctrl_start     <= 1'b0;
            ctrl_soft_rst  <= 1'b0;
            clear_done_reg <= 1'b0;
            irq_enable     <= 1'b0;
            cfg_dim_m      <= 16'd4;
            cfg_dim_k      <= 16'd64;
            cfg_dim_n      <= 16'd32;
            cfg_quant_scale<= 16'd16384;
            cfg_quant_shift<= 5'd14;
            cfg_relu_en    <= 1'b1;
            cfg_clip_min   <= -8'sd128;
            cfg_clip_max   <=  8'sd127;
        end else begin
            // Single-cycle control pulses
            ctrl_start     <= 1'b0;
            ctrl_soft_rst  <= 1'b0;
            clear_done_reg <= 1'b0;

            // AW channel handshaking
            if (s_axi_awvalid && !aw_latched && !s_axi_bvalid) begin
                s_axi_awready <= 1'b1;
                awaddr_lat    <= s_axi_awaddr;
                aw_latched    <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end

            // W channel handshaking
            if (s_axi_wvalid && !w_latched && !s_axi_bvalid) begin
                s_axi_wready <= 1'b1;
                wdata_lat    <= s_axi_wdata;
                wstrb_lat    <= s_axi_wstrb;
                w_latched    <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
            end

            // Execute Register Write
            if (wr_en) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00; // OKAY
                aw_latched   <= 1'b0;
                w_latched    <= 1'b0;

                case (effective_addr)
                    ADDR_CTRL: begin
                        if (effective_strb[0]) begin
                            ctrl_start     <= effective_data[0];
                            ctrl_soft_rst  <= effective_data[1];
                            irq_enable     <= effective_data[2];
                            clear_done_reg <= effective_data[3];
                        end
                    end
                    ADDR_DIM_M: begin
                        if (effective_strb[0]) cfg_dim_m[7:0]  <= effective_data[7:0];
                        if (effective_strb[1]) cfg_dim_m[15:8] <= effective_data[15:8];
                    end
                    ADDR_DIM_K: begin
                        if (effective_strb[0]) cfg_dim_k[7:0]  <= effective_data[7:0];
                        if (effective_strb[1]) cfg_dim_k[15:8] <= effective_data[15:8];
                    end
                    ADDR_DIM_N: begin
                        if (effective_strb[0]) cfg_dim_n[7:0]  <= effective_data[7:0];
                        if (effective_strb[1]) cfg_dim_n[15:8] <= effective_data[15:8];
                    end
                    ADDR_QUANT_SCALE: begin
                        if (effective_strb[0]) cfg_quant_scale[7:0]  <= effective_data[7:0];
                        if (effective_strb[1]) cfg_quant_scale[15:8] <= effective_data[15:8];
                    end
                    ADDR_QUANT_SHIFT: begin
                        if (effective_strb[0]) cfg_quant_shift <= effective_data[4:0];
                    end
                    ADDR_LAYER_CFG: begin
                        if (effective_strb[0]) cfg_relu_en  <= effective_data[0];
                        if (effective_strb[1]) cfg_clip_min <= effective_data[15:8];
                        if (effective_strb[2]) cfg_clip_max <= effective_data[23:16];
                    end
                    ADDR_IRQ_CFG: begin
                        if (effective_strb[0]) irq_enable <= effective_data[0];
                    end
                    default: ;
                endcase
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // AXI4-Lite Read Channel
    // -------------------------------------------------------------------------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= 32'd0;
        end else begin
            if (!s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;
                case (s_axi_araddr)
                    ADDR_CTRL:        s_axi_rdata <= {28'd0, clear_done_reg, irq_enable, ctrl_soft_rst, ctrl_start};
                    ADDR_STATUS:      s_axi_rdata <= {8'd0, status_fsm_state, 14'd0, status_done, status_busy};
                    ADDR_DIM_M:       s_axi_rdata <= {16'd0, cfg_dim_m};
                    ADDR_DIM_K:       s_axi_rdata <= {16'd0, cfg_dim_k};
                    ADDR_DIM_N:       s_axi_rdata <= {16'd0, cfg_dim_n};
                    ADDR_QUANT_SCALE: s_axi_rdata <= {16'd0, cfg_quant_scale};
                    ADDR_QUANT_SHIFT: s_axi_rdata <= {27'd0, cfg_quant_shift};
                    ADDR_LAYER_CFG:   s_axi_rdata <= {8'd0, cfg_clip_max, cfg_clip_min, 7'd0, cfg_relu_en};
                    ADDR_PERF_CYCLES: s_axi_rdata <= perf_cycle_count;
                    ADDR_IRQ_CFG:     s_axi_rdata <= {31'd0, irq_enable};
                    ADDR_IP_ID:       s_axi_rdata <= IP_ID;
                    ADDR_IP_VERSION:  s_axi_rdata <= IP_VERSION;
                    default:          s_axi_rdata <= 32'hDEAD_BEEF;
                endcase
            end else begin
                s_axi_arready <= 1'b0;
                if (s_axi_rvalid && s_axi_rready)
                    s_axi_rvalid <= 1'b0;
            end
        end
    end

    // Interrupt output
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn)
            irq_out <= 1'b0;
        else
            irq_out <= irq_enable & status_done;
    end

endmodule
