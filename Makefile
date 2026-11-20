# ==============================================================================
# Project:      EdgeGuard AI Accelerator
# File:         Makefile
# Description:  Build and verification management for EdgeGuard on PYNQ-Z2
# ==============================================================================

.PHONY: all sim model driver synth clean help

all: sim model driver

help:
	@echo "EdgeGuard AI Accelerator Build System"
	@echo "Targets:"
	@echo "  make sim     - Run full Icarus Verilog regression test suite (100% automated)"
	@echo "  make model   - Train vibration neural network, quantize to INT8, export BRAM hex files"
	@echo "  make driver  - Run PYNQ Python hardware driver & CPU benchmark"
	@echo "  make synth   - Build Vivado bitstream and hardware handoff for PYNQ-Z2 (requires Vivado)"
	@echo "  make clean   - Remove generated simulation binaries, waveforms, and build artifacts"

sim:
	@chmod +x scripts/run_all_tests.sh
	@./scripts/run_all_tests.sh

model:
	@python3 model/train_and_quantize.py

driver:
	@python3 pynq/edgeguard_pynq_driver.py

synth:
	@echo "Launching Vivado Bitstream Build for PYNQ-Z2 (xc7z020clg400-1)..."
	@vivado -mode batch -source scripts/build_bitstream.tcl

clean:
	@rm -rf sim_* *.vcd vivado_build/ *.log *.jou
	@echo "Clean completed."
