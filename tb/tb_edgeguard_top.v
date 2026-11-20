// ==============================================================================
// Project:      EdgeGuard AI Accelerator
// Module:       tb_edgeguard_top.v
// Description:  Full-System Self-Checking Testbench for EdgeGuard SoC Accelerator.
//               Simulates AXI4-Lite Register Driver, AXI4-Stream MM2S/S2MM DMA,
//               End-to-End Layer Inference, and Hardware Cycle Profiling.
// ==============================================================================

`timescale 1ns / 1ps

module tb_edgeguard_top;

    reg clk;
    reg rst_n;

    // AXI-Lite signals
    reg  [7:0]  s_axi_awaddr;
    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;
    reg  [7:0]  s_axi_araddr;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;
    wire        irq;

    // AXI-Stream Slave
    reg  [31:0] s_axis_tdata;
    reg         s_axis_tvalid;
    wire        s_axis_tready;
    reg         s_axis_tlast;

    // AXI-Stream Master
    wire [31:0] m_axis_tdata;
    wire        m_axis_tvalid;
    reg         m_axis_tready;
    wire        m_axis_tlast;

    edgeguard_top #(
        .AXI_LITE_ADDR_WIDTH(8),
        .AXI_DATA_WIDTH(32),
        .BRAM_ADDR_WIDTH(10)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .irq(irq),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );

    always #5 clk = ~clk; // 100 MHz clock

    // Concurrent AXI-Stream DMA S2MM Receiver
    reg [31:0] captured_stream_data [0:15];
    integer    captured_stream_count;
    reg        captured_stream_last;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            captured_stream_count <= 0;
            captured_stream_last  <= 0;
        end else if (m_axis_tvalid && m_axis_tready) begin
            captured_stream_data[captured_stream_count] <= m_axis_tdata;
            captured_stream_count <= captured_stream_count + 1;
            captured_stream_last  <= m_axis_tlast;
            $display("[AXI-STREAM DMA RECV] Output Word %0d = 0x%08X (tlast=%b)", 
                     captured_stream_count, m_axis_tdata, m_axis_tlast);
        end
    end

    // --------------------------------------------------------------------------
    // AXI-Lite Helper Tasks
    // --------------------------------------------------------------------------
    task axi_write(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;

            @(posedge clk);
            while (!(s_axi_awready && s_axi_wready)) @(posedge clk);
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;

            while (!s_axi_bvalid) @(posedge clk);
            @(posedge clk);
            s_axi_bready  <= 1'b0;
        end
    endtask

    task axi_read(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;

            @(posedge clk);
            while (!s_axi_arready) @(posedge clk);
            s_axi_arvalid <= 1'b0;

            while (!s_axi_rvalid) @(posedge clk);
            data = s_axi_rdata;
            @(posedge clk);
            s_axi_rready  <= 1'b0;
        end
    endtask

    // --------------------------------------------------------------------------
    // Main Verification Sequence
    // --------------------------------------------------------------------------
    reg [31:0] read_val;
    integer errors = 0;

    initial begin
        $dumpfile("edgeguard.vcd");
        $dumpvars(0, tb_edgeguard_top);

        $display("============================================================");
        $display("   EdgeGuard AI Accelerator - Full SoC System Testbench     ");
        $display("============================================================");

        clk           = 0;
        rst_n         = 0;
        s_axi_awaddr  = 0;
        s_axi_awvalid = 0;
        s_axi_wdata   = 0;
        s_axi_wstrb   = 0;
        s_axi_wvalid  = 0;
        s_axi_bready  = 0;
        s_axi_araddr  = 0;
        s_axi_arvalid = 0;
        s_axi_rready  = 0;
        s_axis_tdata  = 0;
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;
        m_axis_tready = 1;

        #30;
        rst_n = 1;
        #20;

        // 1. Preload Weights, Bias, and Input activations into BRAMs
        $display("[INFO] Initializing On-Chip BRAMs with Test Vibration Model...");
        
        // Input: 4 rows x 4 elements (1 word = 4 elements)
        dut.u_bram_in.ram[0] = {8'sd40, 8'sd30, 8'sd20, 8'sd10};
        dut.u_bram_in.ram[1] = {8'sd10, 8'sd10, 8'sd10, 8'sd10};
        dut.u_bram_in.ram[2] = {8'sd5,  8'sd5,  8'sd5,  8'sd5};
        dut.u_bram_in.ram[3] = {8'sd2,  8'sd2,  8'sd2,  8'sd2};

        // Weight: 4 columns x 4 elements
        dut.u_bram_wgt.ram[0] = {8'sd1, 8'sd0, 8'sd1, 8'sd2};
        dut.u_bram_wgt.ram[1] = {8'sd1, 8'sd1, 8'sd1, 8'sd1};
        dut.u_bram_wgt.ram[2] = {8'sd2, 8'sd2, 8'sd2, 8'sd2};
        dut.u_bram_wgt.ram[3] = {8'sd3, 8'sd3, 8'sd3, 8'sd3};

        // Bias = 0 for all 4 output neurons
        dut.u_bram_bias.ram[0] = 32'sd0;
        dut.u_bram_bias.ram[1] = 32'sd0;
        dut.u_bram_bias.ram[2] = 32'sd0;
        dut.u_bram_bias.ram[3] = 32'sd0;

        // 2. Configure Accelerator Registers via AXI4-Lite
        $display("[INFO] Programming AXI4-Lite Registers...");
        axi_write(8'h08, 32'd4);         // REG_DIM_M = 4
        axi_write(8'h0C, 32'd4);         // REG_DIM_K = 4
        axi_write(8'h10, 32'd4);         // REG_DIM_N = 4
        axi_write(8'h14, 32'd16384);     // REG_QUANT_SCALE = 16384 (0.5 in Q15)
        axi_write(8'h18, 32'd14);        // REG_QUANT_SHIFT = 14
        axi_write(8'h1C, 32'h007F8001);  // REG_LAYER_CFG: ReLU=1, min=-128, max=127

        // Verify register readback
        axi_read(8'h08, read_val);
        $display("[INFO] Register Readback M=%0d", read_val[15:0]);
        if (read_val[15:0] !== 16'd4) errors = errors + 1;

        // 3. Start Accelerator Execution
        $display("[INFO] Triggering Inference via REG_CTRL (bit 0 = 1)...");
        axi_write(8'h00, 32'h00000001);

        // 4. Poll Status Register for Completion
        read_val = 32'd0;
        while (!read_val[1]) begin // Poll bit 1 (done)
            axi_read(8'h04, read_val);
            #10;
        end
        $display("[INFO] Hardware Inference Completed! STATUS=0x%08X", read_val);

        // 5. Read Performance Profiler Cycle Counter
        axi_read(8'h20, read_val);
        $display("[PERF] Hardware Inference Latency: %0d Clock Cycles (@100MHz = %0.2f ns)", 
            read_val, read_val * 10.0);

        // 6. Verify DMA Stream Received Count
        #50;
        if (captured_stream_count > 0) begin
            $display("[PASS] AXI-Stream DMA transfer verified (%0d words captured, tlast=%b)", 
                     captured_stream_count, captured_stream_last);
        end else begin
            $display("[FAIL] No data captured by AXI-Stream master!");
            errors = errors + 1;
        end

        #50;
        $display("============================================================");
        if (errors == 0) begin
            $display("[SUCCESS] EdgeGuard SoC Full-System Simulation PASSED!");
            $display("============================================================");
        end else begin
            $display("[ERROR] Full-System Simulation encountered %0d errors!", errors);
            $display("============================================================");
        end
        $finish;
    end

endmodule
