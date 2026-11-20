# ==============================================================================
# Project:      EdgeGuard AI Accelerator
# Script:       build_bitstream.tcl
# Description:  Automated Vivado Tcl script to package EdgeGuard IP, build the
#               PYNQ-Z2 Zynq-7020 Block Design, run Synthesis & Implementation,
#               and export Bitstream (.bit) & Hardware Handoff (.hwh) for PYNQ.
# Target:       Xilinx Vivado 2020.1+ / PYNQ-Z2 (xc7z020clg400-1)
# ==============================================================================

set project_name "edgeguard_pynq_proj"
set origin_dir   [file normalize "[file dirname [info script]]/.."]
set work_dir     "$origin_dir/vivado_build"
set part_name    "xc7z020clg400-1"

puts "============================================================"
puts " Building EdgeGuard Hardware Overlay for PYNQ-Z2 ($part_name)"
puts " Project Root: $origin_dir"
puts "============================================================"

# Create work directory
file mkdir $work_dir
cd $work_dir

# ------------------------------------------------------------------------------
# 1. Create Vivado Project
# ------------------------------------------------------------------------------
create_project $project_name $work_dir -part $part_name -force
set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]

# ------------------------------------------------------------------------------
# 2. Add Synthesizable RTL Sources
# ------------------------------------------------------------------------------
add_files -norecurse [list \
    "$origin_dir/rtl/systolic_pe.v" \
    "$origin_dir/rtl/systolic_array_4x4.v" \
    "$origin_dir/rtl/requant_channel.v" \
    "$origin_dir/rtl/requant_activation.v" \
    "$origin_dir/rtl/bram_dp.v" \
    "$origin_dir/rtl/axi_lite_regs.v" \
    "$origin_dir/rtl/stream_buffer_ctrl.v" \
    "$origin_dir/rtl/edgeguard_top.v" \
]
update_compile_order -fileset sources_1

# Add Timing and Physical Constraints
add_files -fileset constrs_1 -norecurse "$origin_dir/scripts/edgeguard_pynq_z2.xdc"

# ------------------------------------------------------------------------------
# 3. Create Block Design (Zynq PS + AXI DMA + EdgeGuard IP)
# ------------------------------------------------------------------------------
create_bd_design "edgeguard_bd"
current_bd_design "edgeguard_bd"

# Instantiate Zynq PS7
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable" } $ps7

# Configure PS7: Enable FCLK0 (100MHz), HP0 (High Perf Slave), GP0 (General Purpose Master), IRQ
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.0} \
] $ps7

# Instantiate AXI DMA (Simple DMA mode, Scatter-Gather disabled for ultra low latency)
set axi_dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_mm2s_burst_size {16} \
    CONFIG.c_m_axi_s2mm_data_width {32} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_s2mm_burst_size {16} \
] $axi_dma

# Instantiate EdgeGuard Accelerator Core directly as RTL Block
set edgeguard_inst [create_bd_cell -type module -reference edgeguard_top edgeguard_0]

# Add Interconnects & Reset Infrastructure
set ps_reset [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 ps_reset]
set axi_periph [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_periph]
set_property -dict [list CONFIG.NUM_MI {2}] $axi_periph

set axi_mem_intercon [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_mem_intercon]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $axi_mem_intercon

# Connect Clocks and Resets (100 MHz Fabric)
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
    [get_bd_pins ps_reset/slowest_sync_clk] \
    [get_bd_pins ps7/M_AXI_GP0_ACLK] \
    [get_bd_pins ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins axi_dma/s_axi_lite_aclk] \
    [get_bd_pins axi_dma/m_axi_mm2s_aclk] \
    [get_bd_pins axi_dma/m_axi_s2mm_aclk] \
    [get_bd_pins edgeguard_0/clk] \
    [get_bd_pins axi_periph/ACLK] \
    [get_bd_pins axi_periph/S00_ACLK] \
    [get_bd_pins axi_periph/M00_ACLK] \
    [get_bd_pins axi_periph/M01_ACLK] \
    [get_bd_pins axi_mem_intercon/ACLK] \
    [get_bd_pins axi_mem_intercon/S00_ACLK] \
    [get_bd_pins axi_mem_intercon/S01_ACLK] \
    [get_bd_pins axi_mem_intercon/M00_ACLK]

connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins ps_reset/ext_reset_in]
connect_bd_net [get_bd_pins ps_reset/peripheral_aresetn] \
    [get_bd_pins axi_dma/axi_resetn] \
    [get_bd_pins edgeguard_0/rst_n] \
    [get_bd_pins axi_periph/ARESETN] \
    [get_bd_pins axi_periph/S00_ARESETN] \
    [get_bd_pins axi_periph/M00_ARESETN] \
    [get_bd_pins axi_periph/M01_ARESETN] \
    [get_bd_pins axi_mem_intercon/ARESETN] \
    [get_bd_pins axi_mem_intercon/S00_ARESETN] \
    [get_bd_pins axi_mem_intercon/S01_ARESETN] \
    [get_bd_pins axi_mem_intercon/M00_ARESETN]

# Connect AXI-Lite Control Planes
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_periph/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_periph/M00_AXI] [get_bd_intf_pins axi_dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_periph/M01_AXI] [get_bd_intf_pins edgeguard_0/s_axi]

# Connect High Performance Memory Access (DMA to DDR)
connect_bd_intf_net [get_bd_intf_pins axi_dma/M_AXI_MM2S] [get_bd_intf_pins axi_mem_intercon/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma/M_AXI_S2MM] [get_bd_intf_pins axi_mem_intercon/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_mem_intercon/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]

# Connect AXI-Stream Data Path
connect_bd_intf_net [get_bd_intf_pins axi_dma/M_AXIS_MM2S] [get_bd_intf_pins edgeguard_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins edgeguard_0/m_axis] [get_bd_intf_pins axi_dma/S_AXIS_S2MM]

# Connect Interrupt to PS
connect_bd_net [get_bd_pins edgeguard_0/irq] [get_bd_pins ps7/IRQ_F2P]

# Auto-assign memory address spaces
assign_bd_address

# Validate Block Design
validate_bd_design
save_bd_design

# ------------------------------------------------------------------------------
# 4. Generate HDL Wrapper & Run Synthesis / Implementation
# ------------------------------------------------------------------------------
set bd_file [get_files "edgeguard_bd.bd"]
make_wrapper -files $bd_file -top
add_files -norecurse "$work_dir/$project_name.srcs/sources_1/bd/edgeguard_bd/hdl/edgeguard_bd_wrapper.v"
update_compile_order -fileset sources_1

puts ">>> Launching Synthesis & Implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# ------------------------------------------------------------------------------
# 5. Export Bitstream (.bit) and Hardware Handoff (.hwh) for PYNQ
# ------------------------------------------------------------------------------
file mkdir "$origin_dir/pynq/overlay"
file copy -force "$work_dir/$project_name.runs/impl_1/edgeguard_bd_wrapper.bit" "$origin_dir/pynq/overlay/edgeguard.bit"
file copy -force "$work_dir/$project_name.gen/sources_1/bd/edgeguard_bd/hw_handoff/edgeguard_bd.hwh" "$origin_dir/pynq/overlay/edgeguard.hwh"

# Generate Resource Utilization and Timing Reports
open_run impl_1
report_utilization -file "$origin_dir/docs/utilization.rpt"
report_timing_summary -file "$origin_dir/docs/timing_summary.rpt"

puts "============================================================"
puts " EdgeGuard PYNQ Overlay Generated Successfully!"
puts " Output: $origin_dir/pynq/overlay/edgeguard.bit"
puts " Output: $origin_dir/pynq/overlay/edgeguard.hwh"
puts "============================================================"
