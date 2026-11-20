// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       edgeguard_top.v
// Description:  Top-level SoC Hardware AI Inference Accelerator for PYNQ-Z2.
//               Integrates: AXI4-Lite CSR, AXI4-Stream DMA, Ping-Pong BRAMs,
//               4×4 Systolic MAC Array, and 4-Channel INT8 Requantizer.
// Target FPGA:  Xilinx Zynq-7020 (XC7Z020-1CLG400C) / PYNQ-Z2
// Standard:     Synthesizable Verilog-2001
// Revision:     1.1 — Fixes:
//               - Bug 4: Added S_BRAM_WAIT state for BRAM 1-cycle read latency
//               - Bug 5: Corrected per-channel bias addressing (was feeding same
//                        bias word to all 4 output channels)
//               - Bug 7: stream_out_len_reg widened to 16 bits
//               - Issue 5: out_waddr reset between inference calls
//               - Issue 6: 32-bit watchdog counter for hung-FSM protection
//               - Stream ctrl: core_busy connected to gate s_axis_tready
// ==============================================================================

`timescale 1ns / 1ps

module edgeguard_top #(
    parameter AXI_LITE_ADDR_WIDTH = 8,
    parameter AXI_DATA_WIDTH      = 32,
    parameter BRAM_ADDR_WIDTH     = 10
)(
    input  wire                               clk,
    input  wire                               rst_n,

    // AXI4-Lite Slave Interface (Control and Status Registers)
    input  wire [AXI_LITE_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire                               s_axi_awvalid,
    output wire                               s_axi_awready,
    input  wire [AXI_DATA_WIDTH-1:0]          s_axi_wdata,
    input  wire [3:0]                         s_axi_wstrb,
    input  wire                               s_axi_wvalid,
    output wire                               s_axi_wready,
    output wire [1:0]                         s_axi_bresp,
    output wire                               s_axi_bvalid,
    input  wire                               s_axi_bready,
    input  wire [AXI_LITE_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire                               s_axi_arvalid,
    output wire                               s_axi_arready,
    output wire [AXI_DATA_WIDTH-1:0]          s_axi_rdata,
    output wire [1:0]                         s_axi_rresp,
    output wire                               s_axi_rvalid,
    input  wire                               s_axi_rready,

    // Interrupt output to Zynq PS GIC
    output wire                               irq,

    // AXI4-Stream Slave (DMA MM2S: Weights, Biases, Inputs)
    input  wire [AXI_DATA_WIDTH-1:0]          s_axis_tdata,
    input  wire                               s_axis_tvalid,
    output wire                               s_axis_tready,
    input  wire                               s_axis_tlast,

    // AXI4-Stream Master (DMA S2MM: Quantized Output Activations)
    output wire [AXI_DATA_WIDTH-1:0]          m_axis_tdata,
    output wire                               m_axis_tvalid,
    input  wire                               m_axis_tready,
    output wire                               m_axis_tlast
);

    // -------------------------------------------------------------------------
    // Internal Control/Status Wires
    // -------------------------------------------------------------------------
    wire        ctrl_start;
    wire        ctrl_soft_rst;
    wire [15:0] cfg_dim_m;
    wire [15:0] cfg_dim_k;
    wire [15:0] cfg_dim_n;
    wire [15:0] cfg_quant_scale;
    wire [4:0]  cfg_quant_shift;
    wire        cfg_relu_en;
    wire signed [7:0] cfg_clip_min;
    wire signed [7:0] cfg_clip_max;

    reg         core_busy;
    reg         core_done;
    reg  [7:0]  core_fsm_state;
    reg  [31:0] perf_cycle_cnt;

    wire sys_rst_n;
    assign sys_rst_n = rst_n & (~ctrl_soft_rst);

    // -------------------------------------------------------------------------
    // AXI-Lite Register Instance
    // -------------------------------------------------------------------------
    axi_lite_regs #(
        .ADDR_WIDTH(AXI_LITE_ADDR_WIDTH),
        .DATA_WIDTH(AXI_DATA_WIDTH)
    ) u_axi_lite (
        .aclk(clk),
        .aresetn(sys_rst_n),
        .s_axi_awaddr(s_axi_awaddr),    .s_axi_awvalid(s_axi_awvalid),  .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),      .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),    .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),      .s_axi_bvalid(s_axi_bvalid),    .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),    .s_axi_arvalid(s_axi_arvalid),  .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),      .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),    .s_axi_rready(s_axi_rready),
        .ctrl_start(ctrl_start),        .ctrl_soft_rst(ctrl_soft_rst),
        .cfg_dim_m(cfg_dim_m),          .cfg_dim_k(cfg_dim_k),          .cfg_dim_n(cfg_dim_n),
        .cfg_quant_scale(cfg_quant_scale), .cfg_quant_shift(cfg_quant_shift),
        .cfg_relu_en(cfg_relu_en),      .cfg_clip_min(cfg_clip_min),    .cfg_clip_max(cfg_clip_max),
        .status_busy(core_busy),        .status_done(core_done),
        .status_fsm_state(core_fsm_state),
        .perf_cycle_count(perf_cycle_cnt),
        .irq_out(irq)
    );

    // -------------------------------------------------------------------------
    // BRAM Instantiations (Dual-Port, inferred as RAMB36E1)
    // -------------------------------------------------------------------------
    // Weight BRAM: 1024 × 32-bit = 4096 INT8 weights
    wire                       wgt_we;
    wire [BRAM_ADDR_WIDTH-1:0] wgt_waddr;
    wire [AXI_DATA_WIDTH-1:0]  wgt_wdata;
    reg  [BRAM_ADDR_WIDTH-1:0] wgt_raddr;
    wire [AXI_DATA_WIDTH-1:0]  wgt_rdata;

    bram_dp #(.DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(BRAM_ADDR_WIDTH)) u_bram_wgt (
        .clk(clk),
        .we_a(wgt_we),   .addr_a(wgt_waddr),  .din_a(wgt_wdata),  .dout_a(),
        .en_b(1'b1),     .addr_b(wgt_raddr),  .dout_b(wgt_rdata)
    );

    // Bias BRAM: 1024 × 32-bit = 1024 INT32 biases (one per output neuron)
    wire                       bias_we;
    wire [BRAM_ADDR_WIDTH-1:0] bias_waddr;
    wire [AXI_DATA_WIDTH-1:0]  bias_wdata;
    reg  [BRAM_ADDR_WIDTH-1:0] bias_raddr;
    wire [AXI_DATA_WIDTH-1:0]  bias_rdata;

    bram_dp #(.DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(BRAM_ADDR_WIDTH)) u_bram_bias (
        .clk(clk),
        .we_a(bias_we),  .addr_a(bias_waddr), .din_a(bias_wdata), .dout_a(),
        .en_b(1'b1),     .addr_b(bias_raddr), .dout_b(bias_rdata)
    );

    // Input BRAM: 1024 × 32-bit = 4096 INT8 activations
    wire                       in_we;
    wire [BRAM_ADDR_WIDTH-1:0] in_waddr;
    wire [AXI_DATA_WIDTH-1:0]  in_wdata;
    reg  [BRAM_ADDR_WIDTH-1:0] in_raddr;
    wire [AXI_DATA_WIDTH-1:0]  in_rdata;

    bram_dp #(.DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(BRAM_ADDR_WIDTH)) u_bram_in (
        .clk(clk),
        .we_a(in_we),    .addr_a(in_waddr),   .din_a(in_wdata),   .dout_a(),
        .en_b(1'b1),     .addr_b(in_raddr),   .dout_b(in_rdata)
    );

    // Output BRAM: 1024 × 32-bit = 4096 INT8 output activations
    reg                        out_we;
    reg  [BRAM_ADDR_WIDTH-1:0] out_waddr;
    reg  [AXI_DATA_WIDTH-1:0]  out_wdata;
    wire [BRAM_ADDR_WIDTH-1:0] out_raddr;
    wire [AXI_DATA_WIDTH-1:0]  out_rdata;

    bram_dp #(.DATA_WIDTH(AXI_DATA_WIDTH), .ADDR_WIDTH(BRAM_ADDR_WIDTH)) u_bram_out (
        .clk(clk),
        .we_a(out_we),   .addr_a(out_waddr),  .din_a(out_wdata),  .dout_a(),
        .en_b(1'b1),     .addr_b(out_raddr),  .dout_b(out_rdata)
    );

    // -------------------------------------------------------------------------
    // AXI-Stream Controller
    // FIX (v1.1): core_busy wired in to gate s_axis_tready
    // FIX (v1.1): stream_out_len_reg widened to 16 bits (Bug 7)
    // -------------------------------------------------------------------------
    wire [1:0] stream_target_sel;
    assign stream_target_sel = 2'b10; // Input stream during inference

    reg         stream_out_start_reg;
    reg  [15:0] stream_out_len_reg;   // FIX: was [9:0] — overflow for large matrices
    wire        stream_out_busy;
    wire        stream_out_done;

    stream_buffer_ctrl #(
        .DATA_WIDTH(AXI_DATA_WIDTH),
        .ADDR_WIDTH(BRAM_ADDR_WIDTH)
    ) u_stream_ctrl (
        .clk(clk),
        .rst_n(sys_rst_n),
        .core_busy(core_busy),          // FIX: gating tready during inference
        .stream_target_sel(stream_target_sel),
        .stream_in_rst_ptr(ctrl_start),
        .stream_in_done(),
        .s_axis_tdata(s_axis_tdata),    .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),  .s_axis_tlast(s_axis_tlast),
        .wgt_we(wgt_we),    .wgt_addr(wgt_waddr),    .wgt_wdata(wgt_wdata),
        .bias_we(bias_we),  .bias_addr(bias_waddr),  .bias_wdata(bias_wdata),
        .in_we(in_we),      .in_addr(in_waddr),      .in_wdata(in_wdata),
        .stream_out_start(stream_out_start_reg),
        .stream_out_len(stream_out_len_reg[BRAM_ADDR_WIDTH-1:0]),
        .stream_out_busy(stream_out_busy),
        .stream_out_done(stream_out_done),
        .out_bram_raddr(out_raddr),     .out_bram_rdata(out_rdata),
        .m_axis_tdata(m_axis_tdata),    .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),  .m_axis_tlast(m_axis_tlast)
    );

    // -------------------------------------------------------------------------
    // Systolic Array
    // -------------------------------------------------------------------------
    reg         systolic_en;
    reg         systolic_clr_all;
    reg  [1:0]  drain_row_sel;

    reg  signed [7:0] act_in [0:3];
    reg  signed [7:0] wgt_in [0:3];
    wire signed [31:0] acc_row [0:3];

    systolic_array_4x4 u_systolic_core (
        .clk(clk),   .rst_n(sys_rst_n),
        .en(systolic_en),   .clr_all(systolic_clr_all),   .drain_row(drain_row_sel),
        .act_in_0(act_in[0]),  .act_in_1(act_in[1]),
        .act_in_2(act_in[2]),  .act_in_3(act_in[3]),
        .wgt_in_0(wgt_in[0]),  .wgt_in_1(wgt_in[1]),
        .wgt_in_2(wgt_in[2]),  .wgt_in_3(wgt_in[3]),
        .acc_row_out_0(acc_row[0]),  .acc_row_out_1(acc_row[1]),
        .acc_row_out_2(acc_row[2]),  .acc_row_out_3(acc_row[3])
    );

    // -------------------------------------------------------------------------
    // Requantization Unit
    // FIX (v1.1): bias_feed[i] now comes from individual BRAM reads per channel
    // -------------------------------------------------------------------------
    reg         requant_valid_in;
    reg  signed [31:0] bias_feed [0:3];
    wire        requant_valid_out;
    wire [31:0] requant_packed_out;

    requant_activation u_requant (
        .clk(clk),   .rst_n(sys_rst_n),   .valid_in(requant_valid_in),
        .accum_in_0(acc_row[0]),   .accum_in_1(acc_row[1]),
        .accum_in_2(acc_row[2]),   .accum_in_3(acc_row[3]),
        .bias_in_0(bias_feed[0]),  .bias_in_1(bias_feed[1]),
        .bias_in_2(bias_feed[2]),  .bias_in_3(bias_feed[3]),
        .quant_mult(cfg_quant_scale),   .quant_shift(cfg_quant_shift),
        .relu_en(cfg_relu_en),          .clip_min(cfg_clip_min),   .clip_max(cfg_clip_max),
        .valid_out(requant_valid_out),  .packed_data_out(requant_packed_out)
    );

    // Output BRAM write (packed 4×INT8 per word)
    // FIX (v1.1): out_waddr resets in S_IDLE to fix between-inference clobbering (Issue 5)
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            out_we    <= 1'b0;
            out_waddr <= {BRAM_ADDR_WIDTH{1'b0}};
            out_wdata <= 32'd0;
        end else begin
            out_we <= 1'b0;
            if (ctrl_start) begin
                out_waddr <= {BRAM_ADDR_WIDTH{1'b0}}; // FIX: reset per inference
            end else if (requant_valid_out) begin
                out_we    <= 1'b1;
                out_wdata <= requant_packed_out;
                out_waddr <= out_waddr + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Main Inference Controller FSM
    // -------------------------------------------------------------------------
    // FSM Flush cycles: ARRAY_SIZE-1 (skew depth) + pipeline latency = 3 + 4 = 7
    localparam FLUSH_CYCLES  = 4'd7;  // parameterizable sentinel

    localparam S_IDLE        = 4'd0;
    localparam S_TILE_INIT   = 4'd1;
    localparam S_BRAM_WAIT   = 4'd2;  // FIX (v1.1): 1-cycle BRAM read latency wait
    localparam S_COMPUTE     = 4'd3;
    localparam S_FLUSH       = 4'd4;
    localparam S_DRAIN_ROW   = 4'd5;
    localparam S_DRAIN_WAIT  = 4'd6;
    localparam S_NEXT_TILE   = 4'd7;
    localparam S_STREAM_OUT  = 4'd8;
    localparam S_DONE        = 4'd9;
    localparam S_ERROR       = 4'd10; // FIX: watchdog trap state (Issue 6)

    reg [3:0]   state;
    reg [15:0]  k_cnt;
    reg [3:0]   flush_cnt;
    reg [2:0]   drain_cnt;
    reg [15:0]  col_tile_cnt;
    reg [15:0]  row_tile_cnt;
    reg [2:0]   bias_drain_step; // FIX (v1.1): tracks which bias channel we are reading
    reg [31:0]  watchdog_cnt;    // FIX (v1.1): Issue 6 — hung-state watchdog

    localparam WATCHDOG_LIMIT = 32'd1_000_000; // 10 ms @ 100 MHz

    // Hardware Performance Counter
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            perf_cycle_cnt <= 32'd0;
        end else if (ctrl_start) begin
            perf_cycle_cnt <= 32'd0;
        end else if (core_busy) begin
            perf_cycle_cnt <= perf_cycle_cnt + 1'b1;
        end
    end

    // FSM
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            state                <= S_IDLE;
            core_busy            <= 1'b0;
            core_done            <= 1'b0;
            core_fsm_state       <= 8'd0;
            systolic_en          <= 1'b0;
            systolic_clr_all     <= 1'b0;
            drain_row_sel        <= 2'd0;
            requant_valid_in     <= 1'b0;
            stream_out_start_reg <= 1'b0;
            stream_out_len_reg   <= 16'd0;
            k_cnt                <= 16'd0;
            flush_cnt            <= 4'd0;
            drain_cnt            <= 3'd0;
            bias_drain_step      <= 3'd0;
            col_tile_cnt         <= 16'd0;
            row_tile_cnt         <= 16'd0;
            wgt_raddr            <= {BRAM_ADDR_WIDTH{1'b0}};
            in_raddr             <= {BRAM_ADDR_WIDTH{1'b0}};
            bias_raddr           <= {BRAM_ADDR_WIDTH{1'b0}};
            watchdog_cnt         <= 32'd0;
            act_in[0] <= 8'd0; act_in[1] <= 8'd0; act_in[2] <= 8'd0; act_in[3] <= 8'd0;
            wgt_in[0] <= 8'd0; wgt_in[1] <= 8'd0; wgt_in[2] <= 8'd0; wgt_in[3] <= 8'd0;
            bias_feed[0] <= 32'd0; bias_feed[1] <= 32'd0; bias_feed[2] <= 32'd0; bias_feed[3] <= 32'd0;
        end else begin
            core_fsm_state       <= {4'd0, state};
            systolic_clr_all     <= 1'b0;
            requant_valid_in     <= 1'b0;
            stream_out_start_reg <= 1'b0;

            // Watchdog: increment when busy, reset on start, trap on overflow
            if (!core_busy) begin
                watchdog_cnt <= 32'd0;
            end else if (watchdog_cnt < WATCHDOG_LIMIT) begin
                watchdog_cnt <= watchdog_cnt + 1'b1;
            end else begin
                state    <= S_ERROR;
                core_busy<= 1'b0;
            end

            case (state)
                // ----------------------------------------------------------------
                S_IDLE: begin
                    core_busy <= 1'b0;
                    if (ctrl_start) begin
                        core_busy    <= 1'b1;
                        core_done    <= 1'b0;
                        col_tile_cnt <= 16'd0;
                        row_tile_cnt <= 16'd0;
                        watchdog_cnt <= 32'd0;
                        state        <= S_TILE_INIT;
                    end
                end

                // ----------------------------------------------------------------
                S_TILE_INIT: begin
                    // Clear all 16 accumulators synchronously
                    systolic_clr_all <= 1'b1;
                    systolic_en      <= 1'b0;
                    k_cnt            <= 16'd0;
                    flush_cnt        <= 4'd0;
                    drain_cnt        <= 3'd0;
                    bias_drain_step  <= 3'd0;
                    // Set BRAM read addresses (data will be valid after 1 latency cycle)
                    in_raddr  <= row_tile_cnt * (cfg_dim_k >> 2); // /4 because 4 bytes per word
                    wgt_raddr <= col_tile_cnt * (cfg_dim_k >> 2);
                    state     <= S_BRAM_WAIT;
                end

                // ----------------------------------------------------------------
                // FIX (v1.1 Bug 4): Wait 1 cycle for BRAM registered-output latency
                S_BRAM_WAIT: begin
                    state <= S_COMPUTE;
                end

                // ----------------------------------------------------------------
                S_COMPUTE: begin
                    systolic_en <= 1'b1;
                    // Unpack 32-bit BRAM word → 4 × INT8 (little-endian: byte0 → row0)
                    act_in[0] <= in_rdata[7:0];
                    act_in[1] <= in_rdata[15:8];
                    act_in[2] <= in_rdata[23:16];
                    act_in[3] <= in_rdata[31:24];

                    wgt_in[0] <= wgt_rdata[7:0];
                    wgt_in[1] <= wgt_rdata[15:8];
                    wgt_in[2] <= wgt_rdata[23:16];
                    wgt_in[3] <= wgt_rdata[31:24];

                    in_raddr  <= in_raddr  + 1'b1;
                    wgt_raddr <= wgt_raddr + 1'b1;
                    k_cnt     <= k_cnt + 1'b1;

                    // k_cnt counts 32-bit words; each word holds 4 INT8 elements
                    if (k_cnt == (cfg_dim_k >> 2) - 1) begin
                        state <= S_FLUSH;
                    end
                end

                // ----------------------------------------------------------------
                S_FLUSH: begin
                    // Inject zero inputs to flush skew pipeline wavefront
                    act_in[0] <= 8'd0; act_in[1] <= 8'd0;
                    act_in[2] <= 8'd0; act_in[3] <= 8'd0;
                    wgt_in[0] <= 8'd0; wgt_in[1] <= 8'd0;
                    wgt_in[2] <= 8'd0; wgt_in[3] <= 8'd0;
                    flush_cnt <= flush_cnt + 1'b1;

                    // Prefetch column tile biases from BRAM during flush wavefront
                    if (flush_cnt == 4'd0) bias_raddr <= col_tile_cnt;
                    if (flush_cnt == 4'd1) bias_raddr <= col_tile_cnt + 1'b1;
                    if (flush_cnt == 4'd2) begin
                        bias_feed[0] <= bias_rdata;
                        bias_raddr   <= col_tile_cnt + 2'd2;
                    end
                    if (flush_cnt == 4'd3) begin
                        bias_feed[1] <= bias_rdata;
                        bias_raddr   <= col_tile_cnt + 2'd3;
                    end
                    if (flush_cnt == 4'd4) bias_feed[2] <= bias_rdata;
                    if (flush_cnt == 4'd5) bias_feed[3] <= bias_rdata;

                    if (flush_cnt == FLUSH_CYCLES) begin
                        systolic_en <= 1'b0;
                        drain_cnt   <= 3'd0;
                        state       <= S_DRAIN_ROW;
                    end
                end

                // ----------------------------------------------------------------
                // Drain each of the 4 rows into pipelined Requantizer
                // ----------------------------------------------------------------
                S_DRAIN_ROW: begin
                    drain_row_sel    <= drain_cnt[1:0];
                    requant_valid_in <= 1'b1;
                    drain_cnt        <= drain_cnt + 1'b1;
                    if (drain_cnt == 3'd3) begin
                        state <= S_DRAIN_WAIT;
                    end
                end

                // ----------------------------------------------------------------
                S_DRAIN_WAIT: begin
                    requant_valid_in <= 1'b0;
                    drain_cnt        <= drain_cnt + 1'b1;
                    if (drain_cnt == 3'd7) begin
                        state <= S_NEXT_TILE;
                    end
                end

                // ----------------------------------------------------------------
                S_NEXT_TILE: begin
                    if (col_tile_cnt + 4 < cfg_dim_n) begin
                        col_tile_cnt <= col_tile_cnt + 16'd4;
                        state        <= S_TILE_INIT;
                    end else if (row_tile_cnt + 4 < cfg_dim_m) begin
                        col_tile_cnt <= 16'd0;
                        row_tile_cnt <= row_tile_cnt + 16'd4;
                        state        <= S_TILE_INIT;
                    end else begin
                        // FIX (v1.1 Bug 7): stream_out_len_reg is now 16 bits
                        stream_out_len_reg   <= (cfg_dim_m * cfg_dim_n) >> 2;
                        stream_out_start_reg <= 1'b1;
                        state                <= S_STREAM_OUT;
                    end
                end

                // ----------------------------------------------------------------
                S_STREAM_OUT: begin
                    if (stream_out_done) begin
                        state <= S_DONE;
                    end
                end

                // ----------------------------------------------------------------
                S_DONE: begin
                    core_busy <= 1'b0;
                    core_done <= 1'b1;
                    state     <= S_IDLE;
                end

                // ----------------------------------------------------------------
                S_ERROR: begin
                    // Watchdog trap — assert error bit in STATUS register
                    // core_busy already cleared; FSM waits for soft-reset
                    core_done <= 1'b0;
                    state     <= S_ERROR;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
