#!/usr/bin/env python3
"""Export a quantized MLP to the tiny-gpu graph IR.

This is the "frontend": it is the ONLY place a model comes from. It emits a
JSON graph that the Rust compiler (src/bin/graph_compiler.rs) turns into a data
image + kernel. Nothing about the model reaches the FPGA any other way -- in
particular nothing is baked into the bitstream.

Weights here are deterministic pseudo-random int8, NOT trained: the point of
this milestone is that the compiler produces bit-exact multi-layer inference.
Swapping in trained weights is a change to this file alone -- which is exactly
the property that makes the rest of it a compiler. (torch isn't installed on
this machine, hence stdlib `random`.)

Input is image 0's real 13x13 pooled features, so the shapes match the existing
on-chip MNIST pipeline.

Usage: python3 export_model.py [out.json]
"""
import json, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "mnist_data")


def load_hex(path):
    out = []
    for line in open(path):
        tok = line.split("//")[0].strip()
        if tok:
            out.append(int(tok, 16))
    return out


def qweights(rng, n, lo=-127, hi=127):
    return [rng.randint(lo, hi) for _ in range(n)]


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "models", "mlp_169_32_10.json")
    rng = random.Random(20260915)

    x0 = load_hex(os.path.join(DATA, "features0.hex"))   # 169 pooled features, 0..255
    assert len(x0) == 169, len(x0)

    # shift: acc >>> (8 + shift) must land a typical activation in 0..255 without
    # everything saturating. Picked per layer from the worst-case accumulator:
    # K * 255 * 127 is the max, and we aim to put that near the top of the byte.
    def pick_shift(k):
        worst = k * 255 * 127
        s = 0
        while s < 7 and (worst >> (8 + s)) > 255 * 8:
            s += 1
        return s

    layers = [
        {"name": "fc1", "in_features": 169, "out_features": 32,
         "activation": "relu", "shift": pick_shift(169),
         "weights": qweights(rng, 32 * 169)},
        {"name": "fc2", "in_features": 32, "out_features": 10,
         "activation": "relu", "shift": pick_shift(32),
         "weights": qweights(rng, 10 * 32)},
    ]

    model = {
        "model_name": "mlp_169_32_10",
        "memory_budget_bytes": 8192,   # main_memory.sv ADDR_BITS = 13
        "input": {"name": "x0", "data": x0},
        "layers": layers,
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(model, f)
    total = sum(l["in_features"] * l["out_features"] for l in layers)
    print(f"wrote {out_path}: {len(layers)} layers, {total} weights, "
          f"shifts={[l['shift'] for l in layers]}")


if __name__ == "__main__":
    main()
