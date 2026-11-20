# ==============================================================================
# Project:      EdgeGuard AI Accelerator
# File:         edgeguard_pynq_z2.xdc
# Description:  Physical and Timing Constraints for Digilent PYNQ-Z2 (XC7Z020-1CLG400C)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Primary Clock Constraints (100 MHz Fabric Clock)
# ------------------------------------------------------------------------------
create_clock -period 10.000 -name clk_100mhz [get_pins -hierarchical *ps7/FCLK_CLK0]

# Set maximum delay for cross-clock domain or asynchronous reset
set_false_path -through [get_pins -hierarchical *ps_reset/peripheral_aresetn]

# ------------------------------------------------------------------------------
# 2. Timing Budget & Clock Uncertainty
# ------------------------------------------------------------------------------
set_clock_uncertainty 0.200 [get_clocks clk_100mhz]

# ------------------------------------------------------------------------------
# 3. Optional On-Board Physical Visualizers (PYNQ-Z2 User LEDs)
#    These allow direct physical inspection of inference states during demos.
# ------------------------------------------------------------------------------
# LED 0: Inference Done (Active High)
# set_property -dict { PACKAGE_PIN R14   IOSTANDARD LVCMOS33 } [get_ports { led_done }];
# LED 1: Accelerator Busy / Computing (Active High)
# set_property -dict { PACKAGE_PIN P14   IOSTANDARD LVCMOS33 } [get_ports { led_busy }];
# LED 2: Hardware Interrupt Pending
# set_property -dict { PACKAGE_PIN N16   IOSTANDARD LVCMOS33 } [get_ports { led_irq  }];
# LED 3: Watchdog / Error Flag
# set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { led_err  }];

# ------------------------------------------------------------------------------
# 4. DSP & BRAM Placement Strategies
# ------------------------------------------------------------------------------
# Direct DSP48E1 packing for systolic array
set_property DONT_TOUCH TRUE [get_cells -hierarchical *u_systolic_core*]
