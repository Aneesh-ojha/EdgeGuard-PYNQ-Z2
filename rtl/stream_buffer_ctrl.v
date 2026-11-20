// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       stream_buffer_ctrl.v
// Description:  AXI4-Stream Interface and Buffer Controller.
//               Manages incoming AXI-Stream (DMA MM2S) for Weight/Bias/Input BRAMs
//               and outgoing AXI-Stream (DMA S2MM) for Quantized Output activations.
// Target FPGA:  Xilinx Zynq-7020 (XC7Z020-1CLG400C) / PYNQ-Z2
// Standard:     AMBA AXI4-Stream Protocol Compliant
// ==============================================================================

`timescale 1ns / 1ps

module stream_buffer_ctrl #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 10
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // Accelerator core busy status (gates s_axis_tready)
    input  wire                   core_busy,

    // Mode Configuration (from CSR)
    // 2'b00: Load Weights, 2'b01: Load Biases, 2'b10: Load Inputs
    input  wire [1:0]             stream_target_sel,
    input  wire                   stream_in_rst_ptr,
    output reg                    stream_in_done,

    // AXI4-Stream Slave (Incoming data from DMA MM2S)
    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tlast,

    // BRAM Write Ports
    output reg                    wgt_we,
    output reg  [ADDR_WIDTH-1:0]  wgt_addr,
    output reg  [DATA_WIDTH-1:0]  wgt_wdata,

    output reg                    bias_we,
    output reg  [ADDR_WIDTH-1:0]  bias_addr,
    output reg  [DATA_WIDTH-1:0]  bias_wdata,

    output reg                    in_we,
    output reg  [ADDR_WIDTH-1:0]  in_addr,
    output reg  [DATA_WIDTH-1:0]  in_wdata,

    // Output Stream Control (Outgoing data to DMA S2MM)
    input  wire                   stream_out_start,
    input  wire [ADDR_WIDTH-1:0]  stream_out_len,
    output reg                    stream_out_busy,
    output reg                    stream_out_done,

    // Output BRAM Read Port
    output reg  [ADDR_WIDTH-1:0]  out_bram_raddr,
    input  wire [DATA_WIDTH-1:0]  out_bram_rdata,

    // AXI4-Stream Master (Outgoing to DMA S2MM)
    output reg  [DATA_WIDTH-1:0]  m_axis_tdata,
    output reg                    m_axis_tvalid,
    input  wire                   m_axis_tready,
    output reg                    m_axis_tlast
);

    // Stream Slave ready when not in reset and core not actively computing
    assign s_axis_tready = rst_n && !core_busy;

    // -------------------------------------------------------------------------
    // Incoming Stream Demux to BRAMs
    // -------------------------------------------------------------------------
    reg [ADDR_WIDTH-1:0] in_ptr;
    reg [ADDR_WIDTH-1:0] wgt_ptr;
    reg [ADDR_WIDTH-1:0] bias_ptr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_ptr         <= {ADDR_WIDTH{1'b0}};
            wgt_ptr        <= {ADDR_WIDTH{1'b0}};
            bias_ptr       <= {ADDR_WIDTH{1'b0}};
            wgt_we         <= 1'b0;
            wgt_addr       <= {ADDR_WIDTH{1'b0}};
            wgt_wdata      <= {DATA_WIDTH{1'b0}};
            bias_we        <= 1'b0;
            bias_addr      <= {ADDR_WIDTH{1'b0}};
            bias_wdata     <= {DATA_WIDTH{1'b0}};
            in_we          <= 1'b0;
            in_addr        <= {ADDR_WIDTH{1'b0}};
            in_wdata       <= {DATA_WIDTH{1'b0}};
            stream_in_done <= 1'b0;
        end else begin
            wgt_we         <= 1'b0;
            bias_we        <= 1'b0;
            in_we          <= 1'b0;
            stream_in_done <= 1'b0;

            if (stream_in_rst_ptr) begin
                in_ptr   <= {ADDR_WIDTH{1'b0}};
                wgt_ptr  <= {ADDR_WIDTH{1'b0}};
                bias_ptr <= {ADDR_WIDTH{1'b0}};
            end

            if (s_axis_tvalid && s_axis_tready) begin
                case (stream_target_sel)
                    2'b00: begin
                        wgt_we    <= 1'b1;
                        wgt_addr  <= wgt_ptr;
                        wgt_wdata <= s_axis_tdata;
                        wgt_ptr   <= wgt_ptr + 1'b1;
                    end
                    2'b01: begin
                        bias_we    <= 1'b1;
                        bias_addr  <= bias_ptr;
                        bias_wdata <= s_axis_tdata;
                        bias_ptr   <= bias_ptr + 1'b1;
                    end
                    2'b10: begin
                        in_we    <= 1'b1;
                        in_addr  <= in_ptr;
                        in_wdata <= s_axis_tdata;
                        in_ptr   <= in_ptr + 1'b1;
                    end
                    default: ;
                endcase
                if (s_axis_tlast)
                    stream_in_done <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Outgoing Stream Master State Machine (BRAM -> AXI-Stream S2MM)
    // Clean 1-cycle latency pipeline with exact tlast on final word
    // -------------------------------------------------------------------------
    localparam SO_IDLE   = 2'd0;
    localparam SO_READ   = 2'd1;
    localparam SO_STREAM = 2'd2;
    localparam SO_DONE   = 2'd3;

    reg [1:0]            so_state;
    reg [ADDR_WIDTH-1:0] out_cnt;
    reg [ADDR_WIDTH-1:0] out_len_lat;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            so_state        <= SO_IDLE;
            out_cnt         <= {ADDR_WIDTH{1'b0}};
            out_len_lat     <= {ADDR_WIDTH{1'b0}};
            out_bram_raddr  <= {ADDR_WIDTH{1'b0}};
            m_axis_tvalid   <= 1'b0;
            m_axis_tdata    <= {DATA_WIDTH{1'b0}};
            m_axis_tlast    <= 1'b0;
            stream_out_busy <= 1'b0;
            stream_out_done <= 1'b0;
        end else begin
            stream_out_done <= 1'b0;

            case (so_state)
                SO_IDLE: begin
                    out_cnt         <= {ADDR_WIDTH{1'b0}};
                    m_axis_tvalid   <= 1'b0;
                    m_axis_tlast    <= 1'b0;
                    if (stream_out_start && (stream_out_len > 0)) begin
                        stream_out_busy <= 1'b1;
                        out_len_lat     <= stream_out_len;
                        out_bram_raddr  <= {ADDR_WIDTH{1'b0}};
                        so_state        <= SO_READ;
                    end else begin
                        stream_out_busy <= 1'b0;
                    end
                end

                SO_READ: begin
                    // BRAM registered data is now available at out_bram_rdata
                    m_axis_tdata  <= out_bram_rdata;
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= (out_cnt == out_len_lat - 1'b1);
                    so_state      <= SO_STREAM;
                end

                SO_STREAM: begin
                    // Hold data and valid until consumer accepts
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (out_cnt == out_len_lat - 1'b1) begin
                            m_axis_tvalid   <= 1'b0;
                            m_axis_tlast    <= 1'b0;
                            stream_out_busy <= 1'b0;
                            stream_out_done <= 1'b1;
                            so_state        <= SO_DONE;
                        end else begin
                            out_cnt        <= out_cnt + 1'b1;
                            out_bram_raddr <= out_cnt + 1'b1;
                            m_axis_tvalid  <= 1'b0; // De-assert during BRAM read cycle
                            m_axis_tlast   <= 1'b0;
                            so_state       <= SO_READ;
                        end
                    end
                end

                SO_DONE: begin
                    so_state <= SO_IDLE;
                end
            endcase
        end
    end

endmodule
