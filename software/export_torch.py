#!/usr/bin/env python3
"""Torch frontend: nn.Module -> quantized SSA graph for graph_compiler.

    capture   torch.fx traces forward() and propagates shapes, so F.relu and
              nn.ReLU, torch.flatten and nn.Flatten all show up
    quantize  int8 weights (per-tensor), u8 activations, one power-of-two
              shift per Linear/Conv2d calibrated on training data
    emit      {tensors, nodes} -- no kernel, no layout; the compiler owns those

The frontend does not know the hardware schedule. It only knows the numeric
contract of FOUT: out = clamp(sum(x*w) >>> (8+shift), 0, 255).

Needs torch + torchvision (~/cnn_chip/venv has both).
Usage: python export_torch.py models/<mnist_mlp|mnist_cnn>.json [--image N] [--epochs E (default per model)]
"""
import json, os, sys
import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.fx as fx
from torch.fx.passes.shape_prop import ShapeProp
from torchvision import datasets

HERE = os.path.dirname(os.path.abspath(__file__))
MNIST_ROOT = os.path.expanduser("~/cnn_chip/data")
MAX_SHIFT = 7   # FOUT's shift field is 3 bits


class MLP(nn.Module):
    input_shape = (169,)          # 13x13, pooled on the host
    epochs = 5

    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(169, 32, bias=False)
        self.fc2 = nn.Linear(32, 10, bias=False)

    def forward(self, x):
        return self.fc2(F.relu(self.fc1(x)))


class CNN(nn.Module):
    input_shape = (1, 28, 28)     # the raw image; the chip does all the work
    epochs = 20

    def __init__(self):
        super().__init__()
        self.conv = nn.Conv2d(1, 2, 3, bias=False)
        self.pool = nn.MaxPool2d(2)
        self.fc = nn.Linear(2 * 13 * 13, 10, bias=False)

    def forward(self, x):
        x = self.pool(F.relu(self.conv(x)))
        return self.fc(torch.flatten(x, 1))


MODELS = {"mnist_mlp": MLP, "mnist_cnn": CNN}


# ---- data: u8 images at the model's input shape ----

def load(train, shape):
    ds = datasets.MNIST(MNIST_ROOT, train=train, download=False)
    x = ds.data.float().unsqueeze(1)                              # N,1,28,28 in 0..255
    if shape[-1] != 28:
        x = F.adaptive_avg_pool2d(x, 13).round().clamp(0, 255)    # N,1,13,13
    return x.reshape(len(x), *shape).to(torch.uint8), ds.targets


# ---- capture ----------------------------------------------------------------

def capture(model):
    """Walk the traced graph into steps (op, module, src, out, out_shape).
    Anything the compiler cannot lower is rejected HERE, by name."""
    gm = fx.symbolic_trace(model)
    ShapeProp(gm).propagate(torch.zeros(1, *model.input_shape))
    mods = dict(gm.named_modules())
    shape = lambda n: list(n.meta["tensor_meta"].shape[1:])     # drop the batch dim
    steps = []
    for n in gm.graph.nodes:
        if n.op == "placeholder":
            continue
        if n.op == "output":
            steps.append(("Argmax", None, n.args[0].name, "out", [1]))
            continue
        src = n.args[0].name
        m = mods.get(n.target) if n.op == "call_module" else None
        if isinstance(m, (nn.Linear, nn.Conv2d)) and m.bias is not None:
            raise SystemExit(f"{n.target}: bias is not supported, use bias=False")
        if isinstance(m, nn.Linear):
            op = "Linear"
        elif isinstance(m, nn.Conv2d):
            if m.stride != (1, 1) or m.padding != (0, 0) or m.dilation != (1, 1) or m.groups != 1:
                raise SystemExit(f"{n.target}: only stride 1, padding 0, dilation 1, groups 1 are supported")
            op = "Conv2d"
        elif isinstance(m, nn.MaxPool2d):
            if m.padding != 0 or (m.stride or m.kernel_size) != m.kernel_size:
                raise SystemExit(f"{n.target}: only stride = kernel_size, padding 0 are supported")
            op = "MaxPool2d"
        elif isinstance(m, nn.ReLU) or n.target in (F.relu, torch.relu):
            op = "Relu"
        elif isinstance(m, nn.Flatten) or n.target is torch.flatten:
            op = "Flatten"
        else:
            raise SystemExit(f"unsupported op in forward(): {n.op} {n.target}")
        steps.append((op, m, src, n.name, shape(n)))
    return steps


# ---- quantize + reference ---------------------------------------------------

def qweight(mod):
    w = mod.weight.detach()
    return torch.round(w * 127.0 / w.abs().max()).clamp(-127, 127).to(torch.int64)


def run_int(steps, qw, shifts, x):
    """Bit-exact software model of the compiled kernel (mirrors graph_compiler's
    eval): FMAC accumulate, FOUT = clamp(acc >>> (8+s), 0, 255), max pool,
    first-wins argmax. Relu is a no-op here because FOUT already clamps at 0.
    Accumulators stay far below 2^53, so float64 conv/matmul is exact."""
    x = x.to(torch.float64)
    accs = []
    for op, m, _, _, _ in steps:
        if op in ("Linear", "Conv2d"):
            w = qw[m].to(torch.float64)
            acc = (x @ w.T if op == "Linear" else F.conv2d(x, w)).to(torch.int64)
            accs.append(acc)
            x = (acc >> (8 + shifts.get(m, 0))).clamp(0, 255).to(torch.float64)
        elif op == "MaxPool2d":
            x = F.max_pool2d(x, m.kernel_size)
        elif op == "Flatten":
            x = x.flatten(1)
    return x.to(torch.int64), accs


def calibrate(steps, qw, x):
    """Pick each layer's shift in order, feeding the already-quantized output of
    the previous layer forward, so later layers calibrate on what the chip sees.
    Shift = smallest that keeps the 99.9th percentile of acc under 255."""
    shifts = {}
    lins = [m for op, m, *_ in steps if op in ("Linear", "Conv2d")]
    for i, m in enumerate(lins):
        _, accs = run_int(steps, qw, shifts, x)
        a = accs[i].clamp(min=0).flatten().float()
        a = a[torch.randperm(len(a), generator=torch.Generator().manual_seed(0))[:1_000_000]]
        hi = torch.quantile(a, 0.999).item()
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
    image = opt("--image", 0)
    name = os.path.splitext(os.path.basename(out_path))[0]
    if name not in MODELS:
        raise SystemExit(f"no model named {name}; known: {', '.join(MODELS)}")
    ckpt = os.path.join(os.path.dirname(out_path), name + ".pt")

    torch.manual_seed(0)
    model = MODELS[name]()
    epochs = opt("--epochs", model.epochs)
    xtr, ytr = load(True, model.input_shape)
    xte, yte = load(False, model.input_shape)

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
    lins = [m for op, m, *_ in steps if op in ("Linear", "Conv2d")]
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
    tensors = {"%x0": {"shape": list(model.input_shape), "data": xte[image].flatten().tolist()}}
    nodes = []
    rename = {steps[0][2]: "%x0"}   # fx value name -> %tensor
    for op, m, src, out, shape in steps:
        rename[out] = f"%{out}"
        tensors[rename[out]] = {"shape": shape}
        node = {"op": op, "name": out, "inputs": [rename[src]], "output": rename[out]}
        if op in ("Linear", "Conv2d"):
            wname = f"%{out}_w"
            tensors[wname] = {"shape": list(m.weight.shape), "data": qw[m].flatten().tolist()}
            node["inputs"].append(wname)
            node["attrs"] = {"shift": shifts[m]}
        elif op == "MaxPool2d":
            node["attrs"] = {"kernel_size": m.kernel_size, "stride": m.stride or m.kernel_size}
        nodes.append(node)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    json.dump({"model_name": name, "memory_budget_bytes": 8192,
               "tensors": tensors, "nodes": nodes}, open(out_path, "w"))
    img_scores, _ = run_int(steps, qw, shifts, xte[image:image + 1])
    print(f"wrote {out_path}: {len(nodes)} nodes, test image {image} "
          f"label {yte[image].item()} -> expect scores {img_scores[0].tolist()}")


if __name__ == "__main__":
    main()
