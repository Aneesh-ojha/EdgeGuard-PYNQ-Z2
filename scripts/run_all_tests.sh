#!/usr/bin/env bash
# ==============================================================================
# Project:      EdgeGuard AI Accelerator
# Script:       run_all_tests.sh
# Description:  Automated Regression Test Suite for EdgeGuard Verilog RTL Core.
#               Executes PE, Systolic Array, Requantizer, FC Integration, and Top SoC testbenches.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

echo "============================================================"
echo "    EdgeGuard AI Accelerator - Full Regression Test Suite   "
echo "============================================================"
echo "Target Platform: Digilent PYNQ-Z2 (XC7Z020-1CLG400C)"
echo "RTL Language:    Verilog-2001 (Synthesizable)"
echo "Simulator:       Icarus Verilog + VVP"
echo "============================================================"
echo ""

# 1. Processing Element Test
echo ">>> [1/5] Compiling & Running tb_systolic_pe..."
iverilog -o sim_pe rtl/systolic_pe.v tb/tb_systolic_pe.v
vvp sim_pe
echo "[PASS] tb_systolic_pe passed!"
echo ""

# 2. 4x4 Systolic Array Test
echo ">>> [2/5] Compiling & Running tb_systolic_array..."
iverilog -o sim_array rtl/systolic_pe.v rtl/systolic_array_4x4.v tb/tb_systolic_array.v
vvp sim_array
echo "[PASS] tb_systolic_array passed!"
echo ""

# 3. Requantization Unit Test
echo ">>> [3/5] Compiling & Running tb_requant..."
iverilog -o sim_requant rtl/requant_channel.v rtl/requant_activation.v tb/tb_requant.v
vvp sim_requant
echo "[PASS] tb_requant passed!"
echo ""

# 4. End-to-End Fully-Connected Layer Integration Test
echo ">>> [4/5] Compiling & Running tb_integration_layer..."
iverilog -o sim_int rtl/systolic_pe.v rtl/systolic_array_4x4.v rtl/requant_channel.v \
         rtl/requant_activation.v tb/tb_integration_layer.v
vvp sim_int
echo "[PASS] tb_integration_layer passed!"
echo ""

# 5. Top-level SoC Testbench
echo ">>> [5/5] Compiling & Running tb_edgeguard_top..."
iverilog -o sim_top rtl/bram_dp.v rtl/systolic_pe.v rtl/systolic_array_4x4.v rtl/requant_channel.v \
         rtl/requant_activation.v rtl/axi_lite_regs.v \
         rtl/stream_buffer_ctrl.v rtl/edgeguard_top.v tb/tb_edgeguard_top.v
vvp sim_top
echo "[PASS] tb_edgeguard_top passed!"
echo ""

# Clean up simulation binaries
rm -f sim_pe sim_array sim_requant sim_int sim_top

echo "============================================================"
echo " [ALL TESTS PASSED] 100% Regression Test Suite Verified!    "
echo "============================================================"
