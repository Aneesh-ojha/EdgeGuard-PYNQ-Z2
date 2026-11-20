#!/usr/bin/env python3
"""
==============================================================================
Project:      EdgeGuard AI Accelerator
Module:       vibration_data_gen.py
Description:  Fast Industrial Vibration Time-Series & 64-Feature Extractor
              simulating standard machinery bearing fault datasets (CWRU/IMS).
              Produces 64 features (8 statistical + 56 frequency sub-band energies)
              for 4 health conditions:
              0: Normal Baseline
              1: Inner Race Fault (BPFI)
              2: Outer Race Fault (BPFO)
              3: Ball Bearing Defect (BSF)
==============================================================================
"""

import math
import random
import json
import os

def generate_vibration_signal(fault_type, num_samples=512, fs=12000.0, rpm=1797.0):
    t = [i / fs for i in range(num_samples)]
    fr = rpm / 60.0  # Shaft rotational frequency (~29.95 Hz)
    
    bpfi = 5.415 * fr  # Inner race: ~162.2 Hz
    bpfo = 3.585 * fr  # Outer race: ~107.4 Hz
    bsf  = 2.322 * fr  # Ball spin:   ~69.5 Hz
    f_res = 2800.0     # Resonance carrier frequency
    
    signal = [0.0] * num_samples
    
    for i in range(num_samples):
        shaft_comp = 0.25 * math.sin(2 * math.pi * fr * t[i]) + \
                     0.15 * math.sin(2 * math.pi * 2 * fr * t[i])
        noise = random.gauss(0.0, 0.12)
        impact = 0.0
        
        if fault_type == 0:  # Normal Baseline
            impact = 0.0
        elif fault_type == 1:  # Inner Race Fault (BPFI)
            mod = 1.0 + 0.8 * math.cos(2 * math.pi * fr * t[i])
            phase = math.fmod(t[i] * bpfi, 1.0)
            pulse = math.exp(-((phase - 0.5) * 14.0) ** 2) if abs(phase - 0.5) < 0.25 else 0.0
            impact = 2.8 * pulse * mod * math.sin(2 * math.pi * f_res * t[i])
        elif fault_type == 2:  # Outer Race Fault (BPFO)
            phase = math.fmod(t[i] * bpfo, 1.0)
            pulse = math.exp(-((phase - 0.5) * 12.0) ** 2) if abs(phase - 0.5) < 0.25 else 0.0
            impact = 2.2 * pulse * math.sin(2 * math.pi * f_res * t[i])
        elif fault_type == 3:  # Ball Defect (BSF)
            mod = 1.0 + 0.5 * math.cos(2 * math.pi * (0.398 * fr) * t[i])
            phase = math.fmod(t[i] * 2 * bsf, 1.0)
            pulse = math.exp(-((phase - 0.5) * 10.0) ** 2) if abs(phase - 0.5) < 0.25 else 0.0
            impact = 1.9 * pulse * mod * math.sin(2 * math.pi * f_res * t[i])
            
        signal[i] = shaft_comp + impact + noise
        
    return signal

def extract_features(signal, num_bands=56):
    n = len(signal)
    mean_val = sum(signal) / n
    variance = sum((x - mean_val) ** 2 for x in signal) / n
    std_dev = math.sqrt(variance) if variance > 1e-9 else 1e-9
    
    rms = math.sqrt(sum(x ** 2 for x in signal) / n)
    peak = max(abs(x) for x in signal)
    crest_factor = peak / (rms + 1e-9)
    kurtosis = sum(((x - mean_val) / std_dev) ** 4 for x in signal) / n
    skewness = sum(((x - mean_val) / std_dev) ** 3 for x in signal) / n
    shape_factor = rms / (sum(abs(x) for x in signal) / n + 1e-9)
    clearance_factor = peak / ((sum(math.sqrt(abs(x)) for x in signal) / n) ** 2 + 1e-9)
    p2p = max(signal) - min(signal)
    
    time_features = [rms, peak, crest_factor, kurtosis, skewness, shape_factor, clearance_factor, p2p]
    
    # Sub-band windowed energy & differences (56 bands)
    sub_band_len = n // num_bands
    freq_bins = [0.0] * num_bands
    for b in range(num_bands):
        sub = signal[b * sub_band_len : (b + 1) * sub_band_len]
        energy = sum(s * s for s in sub) / max(1, len(sub))
        # High-frequency difference
        diff_energy = sum((sub[k] - sub[k-1])**2 for k in range(1, len(sub))) / max(1, len(sub) - 1)
        freq_bins[b] = math.log10(energy + diff_energy * 0.5 + 1e-6)
        
    return time_features + freq_bins

def generate_dataset(num_samples_per_class=40, output_file="data/vibration_dataset.json"):
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    dataset = []
    class_names = ["Normal Baseline", "Inner Race Fault", "Outer Race Fault", "Ball Defect"]
    
    print(f"[DATASET] Generating {num_samples_per_class * 4} synthetic vibration samples...")
    for label in range(4):
        for _ in range(num_samples_per_class):
            sig = generate_vibration_signal(label)
            feat = extract_features(sig)
            dataset.append({
                "label": label,
                "class_name": class_names[label],
                "features": feat
            })
            
    random.shuffle(dataset)
    with open(output_file, "w") as f:
        json.dump(dataset, f, indent=2)
        
    print(f"[DATASET] Successfully saved to {output_file}")
    return dataset

if __name__ == "__main__":
    generate_dataset(num_samples_per_class=30)
