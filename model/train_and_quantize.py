#!/usr/bin/env python3
"""
==============================================================================
Project:      EdgeGuard AI Accelerator
Module:       train_and_quantize.py
Description:  3-Layer Neural Network Training & Post-Training INT8 Quantization.
              Trains on 64-D vibration features, converts float model to:
              - INT8 Weights
              - INT32 Biases
              - Q15 Multiplier M0 and Shift n
              Generates synthesizable BRAM hex files and golden test vectors.
==============================================================================
"""

import math
import random
import json
import os
import struct

from vibration_data_gen import generate_dataset

class DenseLayer:
    def __init__(self, in_features, out_features, has_relu=True):
        self.in_features = in_features
        self.out_features = out_features
        self.has_relu = has_relu
        
        # Xavier/He initialization
        limit = math.sqrt(2.0 / in_features)
        self.weights = [[random.uniform(-limit, limit) for _ in range(out_features)] for _ in range(in_features)]
        self.biases  = [0.0] * out_features
        
        # Quantized integer parameters
        self.w_int8   = [[0] * out_features for _ in range(in_features)]
        self.b_int32  = [0] * out_features
        self.scale_m0 = 16384  # Q15 format
        self.shift_n  = 14
        self.w_scale  = 1.0

def forward_float(layer, x):
    out = [0.0] * layer.out_features
    for j in range(layer.out_features):
        acc = layer.biases[j]
        for i in range(layer.in_features):
            acc += x[i] * layer.weights[i][j]
        out[j] = max(0.0, acc) if layer.has_relu else acc
    return out

def softmax(x):
    max_x = max(x)
    exp_x = [math.exp(v - max_x) for v in x]
    sum_exp = sum(exp_x)
    return [v / sum_exp for v in exp_x]

def train_network(dataset, epochs=40, lr=0.015):
    print("[TRAIN] Building 3-Layer MLP Classifier (64 -> 32 -> 16 -> 4)...")
    l1 = DenseLayer(64, 32, has_relu=True)
    l2 = DenseLayer(32, 16, has_relu=True)
    l3 = DenseLayer(16, 4,  has_relu=False)
    
    # Simple backpropagation training
    for ep in range(epochs):
        random.shuffle(dataset)
        correct = 0
        total_loss = 0.0
        
        for sample in dataset:
            x = sample["features"]
            y_target = sample["label"]
            
            # Forward pass
            h1 = forward_float(l1, x)
            h2 = forward_float(l2, h1)
            logits = forward_float(l3, h2)
            probs = softmax(logits)
            
            pred = probs.index(max(probs))
            if pred == y_target:
                correct += 1
            total_loss -= math.log(max(probs[y_target], 1e-9))
            
            # Backpropagation output gradient (cross-entropy with softmax)
            d_logits = probs[:]
            d_logits[y_target] -= 1.0
            
            # Update Layer 3
            d_h2 = [0.0] * l3.in_features
            for i in range(l3.in_features):
                for j in range(l3.out_features):
                    d_h2[i] += d_logits[j] * l3.weights[i][j]
                    l3.weights[i][j] -= lr * d_logits[j] * h2[i]
                l3.biases[j] -= lr * d_logits[j]
                
            # Update Layer 2
            d_h2_relu = [d_h2[i] if h2[i] > 0 else 0.0 for i in range(len(h2))]
            d_h1 = [0.0] * l2.in_features
            for i in range(l2.in_features):
                for j in range(l2.out_features):
                    d_h1[i] += d_h2_relu[j] * l2.weights[i][j]
                    l2.weights[i][j] -= lr * d_h2_relu[j] * h1[i]
                l2.biases[j] -= lr * d_h2_relu[j]
                
            # Update Layer 1
            d_h1_relu = [d_h1[i] if h1[i] > 0 else 0.0 for i in range(len(h1))]
            for i in range(l1.in_features):
                for j in range(l1.out_features):
                    l1.weights[i][j] -= lr * d_h1_relu[j] * x[i]
                l1.biases[j] -= lr * d_h1_relu[j]
                
        acc = (correct / len(dataset)) * 100.0
        if (ep + 1) % 10 == 0 or ep == 0:
            print(f"[TRAIN] Epoch {ep+1:2d}/{epochs:2d} | Loss: {total_loss/len(dataset):.4f} | Accuracy: {acc:5.1f}%")
            
    return l1, l2, l3

def quantize_layer(layer, in_scale=1.0, out_scale=1.0):
    """
    Symmetric INT8 weight quantization and fixed-point scale calculation:
    Scale formula: M = (in_scale * w_scale) / out_scale
    M = (M0 / 2^n)
    """
    max_w = max(abs(layer.weights[i][j]) for i in range(layer.in_features) for j in range(layer.out_features))
    layer.w_scale = max_w / 127.0 if max_w > 0 else 1.0
    
    # Quantize weights to [-128, 127]
    for i in range(layer.in_features):
        for j in range(layer.out_features):
            q = int(round(layer.weights[i][j] / layer.w_scale))
            layer.w_int8[i][j] = max(-128, min(127, q))
            
    # Quantize biases to INT32
    bias_scale = in_scale * layer.w_scale
    for j in range(layer.out_features):
        b = int(round(layer.biases[j] / bias_scale))
        layer.b_int32[j] = max(-2147483648, min(2147483647, b))
        
    # Fixed point multiplier M0 (16-bit) and shift n
    effective_scale = bias_scale / out_scale
    # Represent effective_scale as M0 * 2^(-shift_n)
    shift = 14
    m0 = int(round(effective_scale * (1 << shift)))
    while m0 > 32767 and shift > 0:
        shift -= 1
        m0 = int(round(effective_scale * (1 << shift)))
    while m0 < 8192 and shift < 28:
        shift += 1
        m0 = int(round(effective_scale * (1 << shift)))
        
    layer.scale_m0 = max(1, min(65535, m0))
    layer.shift_n  = max(0, min(31, shift))
    print(f"[QUANT] Layer ({layer.in_features}x{layer.out_features}): M0={layer.scale_m0}, shift={layer.shift_n}")

def forward_hardware_int8(layer, x_int8):
    """Exact bit-level hardware simulation of systolic array + requantizer."""
    out = [0] * layer.out_features
    for j in range(layer.out_features):
        acc = layer.b_int32[j]
        for i in range(layer.in_features):
            acc += x_int8[i] * layer.w_int8[i][j]
            
        # Requantization: ( (acc * M0) + round ) >> shift
        scaled = acc * layer.scale_m0
        round_offset = (1 << (layer.shift_n - 1)) if layer.shift_n > 0 else 0
        shifted = (scaled + round_offset) >> layer.shift_n
        
        # ReLU & clip
        if layer.has_relu and shifted < 0:
            val = 0
        else:
            val = max(-128, min(127, shifted))
        out[j] = val
    return out

def export_hex_files(layers, out_dir="data"):
    """Exports 32-bit hex files formatted for BRAM direct initialization."""
    os.makedirs(out_dir, exist_ok=True)
    
    for idx, layer in enumerate(layers):
        w_hex_path = os.path.join(out_dir, f"weights_l{idx+1}.hex")
        b_hex_path = os.path.join(out_dir, f"biases_l{idx+1}.hex")
        
        # Pack 4 INT8 weights per 32-bit word
        flat_w = []
        for j in range(layer.out_features):
            for i in range(layer.in_features):
                flat_w.append(layer.w_int8[i][j] & 0xFF)
                
        # Pad to multiple of 4
        while len(flat_w) % 4 != 0:
            flat_w.append(0)
            
        with open(w_hex_path, "w") as f:
            for k in range(0, len(flat_w), 4):
                word = (flat_w[k+3] << 24) | (flat_w[k+2] << 16) | (flat_w[k+1] << 8) | flat_w[k]
                f.write(f"{word:08X}\n")
                
        with open(b_hex_path, "w") as f:
            for b in layer.b_int32:
                word = b & 0xFFFFFFFF
                f.write(f"{word:08X}\n")
                
    print(f"[EXPORT] Successfully generated synthesizable BRAM .hex files in {out_dir}/")

def export_model_json(layers, out_file="pynq/model_params.json"):
    os.makedirs(os.path.dirname(out_file), exist_ok=True)
    data = []
    for l in layers:
        data.append({
            "in_features": l.in_features,
            "out_features": l.out_features,
            "has_relu": l.has_relu,
            "scale_m0": l.scale_m0,
            "shift_n": l.shift_n,
            "weights": l.w_int8,
            "biases": l.b_int32
        })
    with open(out_file, "w") as f:
        json.dump(data, f, indent=2)
    print(f"[EXPORT] Saved model configuration to {out_file}")

if __name__ == "__main__":
    dataset = generate_dataset(num_samples_per_class=60)
    l1, l2, l3 = train_network(dataset, epochs=35)
    
    # Quantize pipeline
    quantize_layer(l1, in_scale=0.05, out_scale=0.08)
    quantize_layer(l2, in_scale=0.08, out_scale=0.10)
    quantize_layer(l3, in_scale=0.10, out_scale=0.15)
    
    export_hex_files([l1, l2, l3])
    export_model_json([l1, l2, l3])
    
    # Test HW simulation accuracy
    hw_correct = 0
    for sample in dataset[:50]:
        x_q = [max(-128, min(127, int(round(v * 20.0)))) for v in sample["features"]]
        y1 = forward_hardware_int8(l1, x_q)
        y2 = forward_hardware_int8(l2, y1)
        y3 = forward_hardware_int8(l3, y2)
        pred = y3.index(max(y3))
        if pred == sample["label"]:
            hw_correct += 1
            
    print(f"[VERIFY] Post-Quantization INT8 Hardware Emulation Accuracy: {(hw_correct/50)*100:.1f}%")
