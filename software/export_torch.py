#!/usr/bin/env python3
"""Torch frontend: nn.Module -> quantized SSA graph for graph_compiler.

    capture   torch.fx traces forward(), so F.relu and nn.ReLU both show up
    quantize  int8 weights (per-tensor), u8 activations, one power-of-two
              shift per Linear calibrated on training data
    emit      {tensors, nodes} -- no kernel, no layout; the compiler owns those

The frontend does not know the hardware schedule. It only knows the numeric
contract of FOUT: out = clamp(sum(x*w) >>> (8+shift), 0, 255).

Needs torch + torchvision (~/cnn_chip/venv has both).
Usage: python export_torch.py [out.json] [--image N] [--epochs E]
"""
import json, os, sys
import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.fx as fx
from torchvision import datasets

HERE = os.path.dirname(os.path.abspath(__file__))
MNIST_ROOT = os.path.expanduser("~/cnn_chip/data")
MAX_SHIFT = 7   # FOUT's shift field is 3 bits


class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(169, 32, bias=False)
        self.fc2 = nn.Linear(32, 10, bias=False)

    def forward(self, x):
        return self.fc2(F.relu(self.fc1(x)))


# ---- data: 28x28 -> 13x13 u8, the input width the on-chip pipeline uses ----

def load(train):
    ds = datasets.MNIST(MNIST_ROOT, train=train, download=False)
    x = ds.data.float().unsqueeze(1)                       # N,1,28,28 in 0..255
    x = F.adaptive_avg_pool2d(x, 13).round().clamp(0, 255)  # N,1,13,13
    return x.flatten(1).to(torch.uint8), ds.targets


# ---- capture ----------------------------------------------------------------

def capture(model):
    """Walk the traced graph into (op, module-or-None, arg name, out name) steps.
    Anything the compiler cannot lower is rejected HERE, by name."""
    gm = fx.symbolic_trace(model)
    mods = dict(gm.named_modules())
    steps = []
    for n in gm.graph.nodes:
        if n.op == "placeholder":
            continue
        if n.op == "output":
            steps.append(("Argmax", None, n.args[0].name, "out"))
            continue
        src = n.args[0].name
        m = mods.get(n.target) if n.op == "call_module" else None
        if isinstance(m, nn.Linear):
            if m.bias is not None:
                raise SystemExit(f"{n.target}: bias is not supported, use bias=False")
            steps.append(("Linear", m, src, n.name))
        elif isinstance(m, nn.ReLU) or n.target in (F.relu, torch.relu):
            steps.append(("Relu", None, src, n.name))
        else:
            raise SystemExit(f"unsupported op in forward(): {n.op} {n.target}")
    return steps


# ---- quantize + reference ---------------------------------------------------

def qweight(lin):
    w = lin.weight.detach()
    return torch.round(w * 127.0 / w.abs().max()).clamp(-127, 127).to(torch.int64)


def run_int(steps, qw, shifts, x):
    """Bit-exact software model of the compiled kernel (mirrors graph_compiler's
    eval): FMAC accumulate, FOUT = clamp(acc >>> (8+s), 0, 255), first-wins argmax.
    Relu is a no-op here because FOUT already clamps at 0."""
    x = x.to(torch.int64)
    accs = []
    for op, m, _, _ in steps:
        if op == "Linear":
            acc = x @ qw[m].T
            accs.append(acc)
            if shifts is not None:
                x = (acc >> (8 + shifts[m])).clamp(0, 255)
    return x, accs


def calibrate(steps, qw, x):
    """Pick each Linear's shift in order, feeding the already-quantized output of
    the previous layer forward, so later layers calibrate on what the chip sees.
    Shift = smallest that keeps the 99.9th percentile of acc under 255."""
    shifts = {}
    lins = [m for op, m, _, _ in steps if op == "Linear"]
    for i, m in enumerate(lins):
        _, accs = run_int(steps, qw, {**shifts, **{l: 0 for l in lins[i:]}}, x)
        hi = torch.quantile(accs[i].clamp(min=0).flatten().float()[:1_000_000], 0.999).item()
        s = 0
        while s < MAX_SHIFT and hi / 2 ** (8 + s) > 255:
            s += 1
        shifts[m] = s
    return shifts


def accuracy(pred, y):
    return (pred == y).float().mean().item() * 100


# ---- main -------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    out_path = next((a for a in args if a.endswith(".json")), os.path.join(HERE, "models", "mnist_mlp.json"))
    opt = lambda k, d: int(args[args.index(k) + 1]) if k in args else d
    image, epochs = opt("--image", 0), opt("--epochs", 5)
    name = os.path.splitext(os.path.basename(out_path))[0]
    ckpt = os.path.join(os.path.dirname(out_path), name + ".pt")

    torch.manual_seed(0)
    xtr, ytr = load(True)
    xte, yte = load(False)
    model = Net()

    if os.path.exists(ckpt):
        model.load_state_dict(torch.load(ckpt))
        print(f"loaded {ckpt} (delete it to retrain)")
    else:
        opt_ = torch.optim.Adam(model.parameters(), lr=1e-3)
        for ep in range(epochs):
            perm = torch.randperm(len(xtr))
            for i in range(0, len(xtr), 128):
                idx = perm[i:i + 128]
                loss = F.cross_entropy(model(xtr[idx].float() / 255), ytr[idx])
                opt_.zero_grad(); loss.backward(); opt_.step()
            print(f"epoch {ep + 1}/{epochs} loss {loss.item():.3f}")
        torch.save(model.state_dict(), ckpt)

    steps = capture(model)
    lins = [m for op, m, _, _ in steps if op == "Linear"]
    qw = {m: qweight(m) for m in lins}
    shifts = calibrate(steps, qw, xtr[:10000])

    with torch.no_grad():
        float_acc = accuracy(model(xte.float() / 255).argmax(1), yte)
    scores, _ = run_int(steps, qw, shifts, xte)
    int_acc = accuracy(scores.argmax(1), yte)   # torch argmax is first-wins, like the kernel
    all_zero = (scores.max(1).values == 0).float().mean().item() * 100
    print(f"float {float_acc:.2f}%   chip-exact int8 {int_acc:.2f}%   "
          f"all-zero score rows {all_zero:.2f}%   shifts {[shifts[m] for m in lins]}")

    # ---- emit the graph ----
    x0 = xte[image].tolist()
    tensors = {"%x0": {"shape": [169], "data": x0}}
    nodes = []
    rename = {}                     # fx value name -> %tensor
    first_input = steps[0][2]
    rename[first_input] = "%x0"
    for i, (op, m, src, out) in enumerate(steps):
        if op == "Linear":
            wname = f"%{out}_w"
            tensors[wname] = {"shape": list(m.weight.shape), "data": qw[m].flatten().tolist()}
            rename[out] = f"%{out}"
            tensors[rename[out]] = {"shape": [m.out_features]}
            node = {"op": op, "name": out, "inputs": [rename[src], wname],
                    "output": rename[out], "attrs": {"shift": shifts[m]}}
        else:
            rename[out] = f"%{out}"
            tensors[rename[out]] = {"shape": tensors[rename[src]]["shape"] if op == "Relu" else [1]}
            node = {"op": op, "inputs": [rename[src]], "output": rename[out]}
        nodes.append(node)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    json.dump({"model_name": name, "memory_budget_bytes": 8192,
               "tensors": tensors, "nodes": nodes}, open(out_path, "w"))
    img_scores, _ = run_int(steps, qw, shifts, xte[image:image + 1])
    print(f"wrote {out_path}: {len(nodes)} nodes, test image {image} "
          f"label {yte[image].item()} -> expect scores {img_scores[0].tolist()}")


if __name__ == "__main__":
    main()
