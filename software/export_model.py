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

    # SSA graph: tensors by name, nodes in execution order. The compiler owns
    # fusion (Linear->Relu becomes one FMAC loop + FOUT) and memory placement.
    fc = [("fc1", 169, 32), ("fc2", 32, 10)]
    tensors = {"%x0": {"shape": [169], "data": x0}}
    nodes = []
    x = "%x0"
    for i, (name, fin, fout) in enumerate(fc, 1):
        w, z, a = f"%w{i}", f"%z{i}", f"%x{i}"
        tensors[w] = {"shape": [fout, fin], "data": qweights(rng, fout * fin)}
        tensors[z] = {"shape": [fout]}
        tensors[a] = {"shape": [fout]}
        nodes.append({"op": "Linear", "name": name, "inputs": [x, w], "output": z,
                      "attrs": {"shift": pick_shift(fin)}})
        nodes.append({"op": "Relu", "inputs": [z], "output": a})
        x = a
    tensors["%out"] = {"shape": [1]}
    nodes.append({"op": "Argmax", "inputs": [x], "output": "%out"})

    model = {
        "model_name": "mlp_169_32_10",
        "memory_budget_bytes": 8192,   # main_memory.sv ADDR_BITS = 13
        "tensors": tensors,
        "nodes": nodes,
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(model, f)
    print(f"wrote {out_path}: {len(nodes)} nodes, "
          f"shifts={[n['attrs']['shift'] for n in nodes if n['op'] == 'Linear']}")


if __name__ == "__main__":
    main()
