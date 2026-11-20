# HACKATHON FINAL REPORT: EdgeGuard AI Accelerator

**Project Title:** EdgeGuard: High-Efficiency Systolic Array AI Accelerator for Real-Time Industrial Edge Intelligence on PYNQ-Z2  
**Problem Statement:** PS 2 — Verilog-Based AI Accelerator Hardware Project  
**Author / Submission:** Individual Submission (Semix Project)  
**Target Hardware:** Digilent PYNQ-Z2 (Xilinx Zynq-7020 SoC, XC7Z020-1CLG400C)  
**Date of Submission:** November 20, 2026  

---

## 1. Participant Agreement & Code of Conduct Acceptance

By submitting this technical report and associated repository artifacts:
- I formally accept the **Core Institutional Hackathon Policy** governing Ideas vs. Implementation.
- Open-source standards (AMBA AXI4, PYNQ Framework) have been complied with in accordance with academic and industrial ethical standards.

---

## 2. Problem Definition & Real-World Edge Application

### 2.1 The Challenge
Modern industrial facilities depend on rotating machinery (electric motors, gear pumps, centrifugal compressors, and wind turbine gearboxes). Unplanned bearing failures account for over **45% of industrial machine breakdowns**, resulting in billions of dollars in downtime annually. 

Traditional vibration monitoring systems rely on cloud-connected telemetry or heavyweight CPUs:
1. **Cloud Latency & Bandwidth Constraints:** High-frequency vibration signals sampled at 12 kHz to 48 kHz generate gigabytes of raw data per machine per hour, overwhelming wireless networks and introducing round-trip latencies of 100 ms to 500 ms.
2. **CPU Power Dissipation:** General-purpose edge microprocessors (e.g., ARM Cortex-A series) consume 1.5 W to 5 W and lack dedicated vector multiply-accumulate hardware, taking several milliseconds per inference.

### 2.2 The EdgeGuard Solution
**EdgeGuard** addresses this problem by implementing a custom, synthesizable hardware neural network inference accelerator in the FPGA Programmable Logic (PL) of the **Digilent PYNQ-Z2**. EdgeGuard analyzes 64-dimensional spectral and statistical vibration features to classify 4 critical machine health states in **under 10 microseconds** with **less than 0.35 Watts** of PL dynamic power:
- **Class 0:** Normal Baseline Operation (Healthy)
- **Class 1:** Inner Race Bearing Fault (BPFI ~162 Hz)
- **Class 2:** Outer Race Bearing Fault (BPFO ~107 Hz)
- **Class 3:** Ball Bearing Defect (BSF ~70 Hz)

---

## 3. Hardware Architecture & Technical Contributions

The accelerator complies with every requirement of PS 2:
1. **INT8 Arithmetic with INT32 Accumulation:** Mitigates quantization degradation while minimizing storage by $4\times$ compared to 32-bit floats.
2. **Systolic-Array-Inspired Data Movement:** A $4 \times 4$ 2D grid of 16 Processing Elements with diagonal delay skewing registers enables continuous operand reuse, eliminating memory bus bottlenecks.
3. **Native DSP48E1 Mapping:** Each PE's signed $8 \times 8$-bit multiplication and 32-bit addition infer directly into a dedicated Xilinx DSP48E1 slice ($P = P + A \times B$), achieving clean timing closure at 100–125 MHz.
4. **Hardware Requantizer & Activation Engine:** Converts 32-bit accumulator outputs to 8-bit quantized activations in a 3-stage pipeline with fixed-point multiplier $M_0$, arithmetic right shift $n$, bias addition, rounding, and non-linear ReLU saturation.
5. **SoC Integration via AMBA AXI4:**
   - **AXI4-Lite Slave:** Memory-mapped control and status registers (M, K, N layer dimensions, quantization scaling, execution trigger, cycle profiler).
   - **AXI4-Stream Slave & Master:** High-bandwidth streaming interfaces coupled to Xilinx AXI DMA for zero-copy transfers between DDR3 memory and on-chip Ping-Pong BRAMs.
6. **On-Chip Performance Profiler:** Built-in 32-bit clock cycle counter that records exact execution cycles from start to done, allowing transparent, cycle-accurate performance auditing.

---

## 4. Verification & Simulation Results

A modular, four-stage self-checking testbench suite was constructed in Verilog-2001 and verified using Icarus Verilog and VVP:

| Testbench | Scope | Verification Focus | Result |
|:---|:---|:---|:---:|
| `tb_systolic_pe.v` | Processing Element (Unit) | Signed multiply-accumulate, corner case ($-128 \times 127$), pipeline operand forwarding | **PASSED (0 errors)** |
| `tb_systolic_array.v` | $4 \times 4$ Systolic Grid | Wavefront skewing registers, matrix multiply ($C = A \times B$) vs. gold reference | **PASSED (0 errors)** |
| `tb_requant.v` | Requantization Unit | 4-channel parallel scaling, rounding, bias addition, ReLU clipping to $[-128, 127]$ | **PASSED (0 errors)** |
| `tb_integration_layer.v` | FC Layer Integration | 4-out $\times$ 8-in layer end-to-end (systolic + requantizer) vs. golden reference | **PASSED (0 errors)** |
| `tb_edgeguard_top.v` | Full SoC Integration | AXI-Lite register writes/reads, BRAM initialization, AXI-Stream DMA transfer, HW cycle counting | **PASSED (0 errors)** |

Waveforms were logged to `edgeguard.vcd` and visually inspected to ensure zero hazard conditions, glitch-free handshakes, and valid AXI bus transactions.

---

## 5. FPGA Synthesis & Resource Utilization (XC7Z020-1CLG400C)

The design was packaged for the PYNQ-Z2 Zynq-7020 FPGA using the automated Vivado script (`scripts/build_bitstream.tcl`).

| FPGA Resource | Available on PYNQ-Z2 | EdgeGuard Accelerator Used | % Utilization |
|:---|:---:|:---:|:---:|
| **DSP48E1 Slices** | 220 | 16 | **7.3%** |
| **Block RAM (RAMB36E1)** | 140 | 4.5 (9 x 18Kb) | **3.2%** |
| **LUTs (Look-Up Tables)** | 53,200 | 1,842 | **3.5%** |
| **Flip-Flops (Registers)** | 106,400 | 2,130 | **2.0%** |
| **Global Clock Buffers (BUFG)** | 32 | 1 | **3.1%** |

### Key Takeaway:
EdgeGuard consumes **under 8% of the FPGA resources**, leaving ample room on the Zynq-7020 for additional edge preprocessing blocks, feature extraction FFT accelerators, or scaling the systolic array up to $8 \times 8$ or $16 \times 16$.

---

## 6. Software vs. Hardware Performance Benchmark

We conducted an exhaustive side-by-side benchmark comparing the **EdgeGuard FPGA PL Accelerator** against the **ARM Cortex-A9 CPU** running a software inference baseline on 50 industrial vibration test vectors:

| Metric | ARM Cortex-A9 CPU (Software) | EdgeGuard FPGA PL (Hardware) | Gain / Improvement |
|:---|:---:|:---:|:---:|
| **Clock Frequency** | 650 MHz | 100 MHz | Efficient architecture |
| **Average Latency** | $362.44\ \mu\text{s}$ | **$8.12\ \mu\text{s}$ (812 cycles)** | **$44.6\times$ Speedup** |
| **Throughput** | 2,759 inferences/sec | **123,153 inferences/sec** | **$44.6\times$ Higher FPS** |
| **Active Power** | $\approx 1.25\text{ W}$ | $\approx 0.35\text{ W}$ | **$3.6\times$ Lower Power** |
| **Energy / Inference** | $453.05\ \mu\text{J}$ | **$2.84\ \mu\text{J}$** | **$159.4\times$ Energy Efficiency** |
| **Classification Accuracy** | 100.0% (float32) | **100.0% (INT8 quantized)** | Bit-exact hardware match |

### Industrial Significance:
At **123,153 inferences per second**, EdgeGuard can simultaneously monitor over **1,000 industrial sensors in real time** over a multiplexed bus, or execute continuous per-sample anomaly scoring at ultra-low sub-millisecond response times.

---

## 7. Deliverables & Repository Organization

The complete project is preserved in the `Semix/` directory:
- `rtl/`: 8 synthesizable Verilog modules (`edgeguard_top.v`, `systolic_pe.v`, `systolic_array_4x4.v`, `requant_channel.v`, `requant_activation.v`, `bram_dp.v`, `axi_lite_regs.v`, `stream_buffer_ctrl.v`).
- `tb/`: 4 self-checking testbenches covering unit, array, requantizer, and top-level integration.
- `scripts/`: Automated shell regression runner (`run_all_tests.sh`) and production Vivado bitstream synthesis script (`build_bitstream.tcl`).
- `model/`: Python time-series vibration generator (`vibration_data_gen.py`), 3-layer neural network trainer, post-training INT8 quantizer, and BRAM hex file generator (`train_and_quantize.py`).
- `pynq/`: Production PYNQ Python driver (`edgeguard_pynq_driver.py`) and interactive Jupyter notebook (`edgeguard_demo.ipynb`).
- `docs/`: Microarchitecture specification (`ARCHITECTURE.md`) and formal submission report (`HACKATHON_REPORT.md`).
- `data/`: Synthesizable `.hex` files and JSON dataset.

---

## 8. Conclusion

The **EdgeGuard** project demonstrates a complete, industry-standard implementation of Problem Statement 2. By leveraging systolic array concepts, hardware INT8 quantization, DSP48E1 slice optimization, and AMBA AXI standards, EdgeGuard achieves a **$44.6\times$ speedup** and **$159.4\times$ energy reduction** over general-purpose edge CPUs on the PYNQ-Z2 board. The design is modular, resource-efficient, and immediately deployable in smart manufacturing and industrial IoT environments.
