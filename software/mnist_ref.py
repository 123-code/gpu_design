#!/usr/bin/env python3
"""Faithful software model of the cnn_chip / tiny-gpu MNIST pipeline.

Reproduces the RTL exactly so we can verify tiny-gpu's FC-MAC + argmax hardware:
  conv 3x3 valid (28x28->26x26): sum of signed(px)*signed(w); if sum<0 ->0,
    elif (sum>>8)>255 ->255, else sum>>8       (mac_array_3x3.v)
  maxpool 2x2 stride 2 (26->13 = 169)
  FC 169->10: acc32 = sum(px*w); score = acc + int32 bias[digit]; argmax
Also dumps the 169 pooled features to mnist_data/features<idx>.hex for the testbench.

Usage: python3 mnist_ref.py [image_index]
"""
import sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "mnist_data")

def load_hex(path):
    """Hex values, one per line; // comments skipped (as Verilog $readmemh does)."""
    out = []
    with open(path) as f:
        for line in f:
            tok = line.split("//")[0].strip()
            if tok:
                out.append(int(tok, 16))
    return out

def load_labels(path):
    """Parse '// image N label L' comment lines into {N: L}."""
    labels = {}
    with open(path) as f:
        for line in f:
            if "label" in line:
                p = line.split()
                try:
                    labels[int(p[2])] = int(p[4])
                except (IndexError, ValueError):
                    pass
    return labels

def s8(v):  return v - 256 if v > 127 else v
def s32(v): return v - (1 << 32) if v >= (1 << 31) else v


def load_model(data_dir=DATA):
    """Return (weights, biases) from mnist_data/, ready for run_pipeline().
    weights: 1699 raw uint8 (9 conv + 1690 FC); biases: 11 signed int32."""
    weights = load_hex(os.path.join(data_dir, "weights.hex"))
    biases  = [s32(v) for v in load_hex(os.path.join(data_dir, "bias.hex"))]
    return weights, biases


def run_pipeline(img, weights, biases):
    """Bit-exact software model of the on-chip CNN. Given a 784-byte unsigned
    image and the (weights, biases) from load_model(), return the same stages
    the RTL computes:
        conv   : 676 (26x26) quantized conv-map bytes, row-major
        pooled : 169 (13x13) max-pooled bytes, row-major
        scores : 10 int FC scores (acc + int32 bias) per digit
        pred   : argmax digit
    """
    cw  = [s8(weights[i]) for i in range(9)]                # 9 conv weights (signed)
    fcw = [s8(weights[9 + i]) for i in range(1690)]         # 1690 FC weights (signed)
    px = lambda y, x: img[y*28 + x]                         # unsigned pixel

    # --- conv 3x3 valid -> 26x26, quantized exactly like mac_array_3x3.v ---
    conv = [[0]*26 for _ in range(26)]
    for y in range(26):
        for x in range(26):
            s = 0
            for r in range(3):
                for c in range(3):
                    s += px(y+r, x+c) * cw[r*3 + c]
            if s < 0:               conv[y][x] = 0
            elif (s >> 8) > 255:    conv[y][x] = 255
            else:                   conv[y][x] = (s >> 8) & 0xFF

    # --- maxpool 2x2 stride 2 -> 13x13 ---
    pooled = []
    for Y in range(13):
        for X in range(13):
            pooled.append(max(conv[2*Y][2*X],   conv[2*Y][2*X+1],
                              conv[2*Y+1][2*X], conv[2*Y+1][2*X+1]))

    # --- FC 169 -> 10, argmax on (acc + int32 bias) ---
    scores = []
    for d in range(10):
        acc = sum(pooled[i] * fcw[d*169 + i] for i in range(169))
        scores.append(acc + biases[d + 1])   # bias.hex idx 1..10 == digits 0..9
    pred = max(range(10), key=lambda d: scores[d])

    conv_flat = [conv[y][x] for y in range(26) for x in range(26)]
    return {"conv": conv_flat, "pooled": pooled, "scores": scores, "pred": pred}


def main():
    idx = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    weights, biases = load_model()
    imgs = load_hex(os.path.join(DATA, "images_batch.hex"))

    img = imgs[idx*784 : idx*784 + 784]                     # 28x28 unsigned
    out = run_pipeline(img, weights, biases)
    conv_flat, pooled, scores, pred = out["conv"], out["pooled"], out["scores"], out["pred"]
    conv = [conv_flat[y*26:(y+1)*26] for y in range(26)]    # reshape for the dump below
    fcw = [s8(weights[9 + i]) for i in range(1690)]         # 1690 FC weights (for dumps)
    labels = load_labels(os.path.join(DATA, "images_batch.hex"))
    label = labels.get(idx)

    # dump the 169 pooled features for the Verilog testbench
    with open(os.path.join(DATA, f"features{idx}.hex"), "w") as f:
        for v in pooled:
            f.write(f"{v & 0xFF:02X}\n")

    # dump the interleaved FC payload the (off-chip-fed) FC kernel base-sweeps.
    with open(os.path.join(DATA, f"fc_payload{idx}.hex"), "w") as f:
        for d in range(10):
            for i in range(169):
                f.write(f"{pooled[i] & 0xFF:02X}\n")
                f.write(f"{fcw[d*169 + i] & 0xFF:02X}\n")

    # ---- artifacts for the FULL on-chip pipeline ----
    def dump(name, vals):
        with open(os.path.join(DATA, name), "w") as f:
            for v in vals:
                f.write(f"{v & 0xFF:02X}\n")

    # conv 3x3 weights, baked into the MAC coprocessor's weight inputs
    dump("conv_weights.hex", [weights[i] for i in range(9)])      # raw int8 bytes
    # the input image (host streams this; sim preloads it at addr 0)
    dump(f"image{idx}.hex", img)
    # reference intermediate maps for staged sim verification
    dump(f"conv_map{idx}.hex", [conv[y][x] for y in range(26) for x in range(26)])
    dump(f"pool_map{idx}.hex", pooled)

    # FC interleaved buffer INIT (image-independent): even slot = feature
    # placeholder (the GPU scatter fills it), odd slot = baked FC weight.
    # Baked into main_memory at the FC-buffer base; 3380 entries.
    with open(os.path.join(DATA, "fc_buf_init.hex"), "w") as f:
        for d in range(10):
            for i in range(169):
                f.write("00\n")                              # feature slot (GPU fills)
                f.write(f"{fcw[d*169 + i] & 0xFF:02X}\n")    # weight slot (baked)

    tag = "" if label is None else f"  (label {label}, {'HIT' if label == pred else 'miss'})"
    print(f"image {idx}: predicted digit = {pred}{tag}")
    print("scores:", scores)
    print(f"wrote mnist_data/features{idx}.hex (169 pooled bytes)")

if __name__ == "__main__":
    main()
