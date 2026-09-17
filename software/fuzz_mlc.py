#!/usr/bin/env python3
"""Differential fuzzer for the ML compiler: random graph -> compiler -> RTL.

Every case is checked three ways and all three must agree byte for byte:
    ref.py     this file's reference, computed from the graph alone
    expect.hex graph_compiler's eval() of its own lowered model
    RTL        test/tb_mlc.sv running the compiled kernel on the real design

A mismatch between ref and expect is a lowering bug; between expect and RTL a
codegen / assembler / hardware bug. Cases the compiler rejects are counted,
not failed (the planner refusing a model is the correct behavior).

Usage: python3 fuzz_mlc.py [--n 50] [--seed 1] [--jobs 8] [--keep]
Repro one case: python3 fuzz_mlc.py --n 1 --seed <case seed> --keep
"""
import json, os, random, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(HERE, "build", "fuzz")
COMPILER = os.path.join(HERE, "target", "debug", "graph_compiler")
ASSEMBLER = os.path.join(HERE, "target", "debug", "software")
SIM = os.path.join(HERE, "build", "sim_mlc")   # gitignored


# ---- random graphs ----------------------------------------------------------

def weights(rng, n):
    # biased positive: a ReLU'd-to-zero activation hides any bug upstream of it
    mode = rng.choice(["mostly_positive"] * 4 + ["uniform", "positive", "small", "negative", "extreme"])
    pick = {"uniform": lambda: rng.randint(-128, 127),
            "mostly_positive": lambda: rng.randint(-50, 127),
            "small": lambda: rng.randint(-4, 4),
            "positive": lambda: rng.randint(0, 127),
            "negative": lambda: rng.randint(-128, 0),
            "extreme": lambda: rng.choice([-128, -127, 0, 126, 127])}[mode]
    return [pick() for _ in range(n)]


def pixels(rng, n):
    mode = rng.choice(["uniform", "uniform", "uniform", "full", "sparse", "zeros"])
    pick = {"uniform": lambda: rng.randint(0, 255), "zeros": lambda: 0, "full": lambda: 255,
            "sparse": lambda: rng.choice([0, 0, 0, rng.randint(1, 255)])}[mode]
    return [pick() for _ in range(n)]


def random_graph(seed):
    rng = random.Random(seed)
    tensors, nodes = {}, []
    cur = "%x0"

    def add(op, shape, attrs=None, weight=None):
        nonlocal cur
        out = f"%t{len(nodes)}"
        ins = [cur]
        if weight is not None:
            wname = out + "_w"
            tensors[wname] = {"shape": weight[0], "data": weights(rng, prod(weight[0]))}
            ins.append(wname)
        tensors[out] = {"shape": shape}
        node = {"op": op, "name": out[1:], "inputs": ins, "output": out}
        if attrs:
            node["attrs"] = attrs
        nodes.append(node)
        cur = out

    if rng.random() < 0.7:
        h, w = rng.randint(3, 10), rng.randint(3, 10)
        tensors["%x0"] = {"shape": [1, h, w], "data": pixels(rng, h * w)}
        c = 1
        if rng.random() < 0.8:
            k, c = rng.randint(1, min(4, h, w)), rng.randint(1, 3)
            h, w = h - k + 1, w - k + 1
            add("Conv2d", [c, h, w], {"shift": rng.randint(0, 7)}, weight=([c, 1, k, k],))
            add("Relu", [c, h, w])
        if rng.random() < 0.6:
            k = rng.randint(1, min(3, h, w))
            h, w = h // k, w // k
            add("MaxPool2d", [c, h, w], {"kernel_size": k, "stride": k})
        width = c * h * w
        if nodes and width + 1 <= 255 and rng.random() < 0.4:
            # end here: the reply is every activation of the last conv/pool, so a
            # wrong window read cannot hide behind later layers
            add("Argmax", [1])
            return calibrate(rng, seed, tensors, nodes)
        add("Flatten", [width])
    else:
        width = rng.randint(1, 24)
        tensors["%x0"] = {"shape": [width], "data": pixels(rng, width)}

    layers = rng.randint(1, 3)
    for i in range(layers):
        out_f = rng.randint(1, 12)
        add("Linear", [out_f], {"shift": rng.randint(0, 7)}, weight=([out_f, width],))
        if i < layers - 1 or rng.random() < 0.5:
            add("Relu", [out_f])
        width = out_f
    add("Argmax", [1])
    return calibrate(rng, seed, tensors, nodes)


def calibrate(rng, seed, tensors, nodes):
    """Most layers get the smallest shift that keeps their peak in 0..255, like the
    real frontend, so activations stay alive and bugs reach the reply. The rest
    keep a random shift to exercise saturation."""
    g = {"model_name": f"fuzz{seed}", "memory_budget_bytes": 8192, "tensors": tensors, "nodes": nodes}
    for n in nodes:
        if n["op"] in ("Linear", "Conv2d") and rng.random() < 0.75:
            n["attrs"]["shift"] = 0
            peaks = {}
            reference(g, peaks)
            s = 0
            while s < 7 and peaks[n["name"]] >> (8 + s) > 255:
                s += 1
            n["attrs"]["shift"] = s
    return g


def prod(xs):
    p = 1
    for x in xs:
        p *= x
    return p


# ---- independent reference (from the graph, not from the compiler) ------------

def reference(g, peaks=None):
    """What the graph MEANS on this hardware: FOUT = clamp(acc >> (8+shift), 0, 255)
    after every Linear/Conv2d, max pool, row-major flatten, first-wins argmax.
    If `peaks` is a dict, it collects each layer's largest accumulator."""
    T = g["tensors"]
    x = T["%x0"]["data"]
    shape = T["%x0"]["shape"]
    def fout(acc, s):
        if peaks is not None:
            peaks[n["name"]] = max(peaks.get(n["name"], 0), acc)
        return max(0, min(255, acc >> (8 + s)))
    for n in g["nodes"]:
        op, a = n["op"], n.get("attrs", {})
        if op == "Linear":
            (o, i), w = T[n["inputs"][1]]["shape"], T[n["inputs"][1]]["data"]
            x = [fout(sum(x[k] * w[m * i + k] for k in range(i)), a["shift"]) for m in range(o)]
            shape = [o]
        elif op == "Conv2d":
            (co, _, k, _), w = T[n["inputs"][1]]["shape"], T[n["inputs"][1]]["data"]
            _, h, wd = shape
            oh, ow = h - k + 1, wd - k + 1
            x = [fout(sum(x[(oy + ky) * wd + ox + kx] * w[c * k * k + ky * k + kx]
                          for ky in range(k) for kx in range(k)), a["shift"])
                 for c in range(co) for oy in range(oh) for ox in range(ow)]
            shape = [co, oh, ow]
        elif op == "MaxPool2d":
            k = a["kernel_size"]
            c, h, wd = shape
            oh, ow = h // k, wd // k
            x = [max(x[ch * h * wd + (oy * k + ky) * wd + ox * k + kx] for ky in range(k) for kx in range(k))
                 for ch in range(c) for oy in range(oh) for ox in range(ow)]
            shape = [c, oh, ow]
        elif op == "Flatten":
            shape = [len(x)]
        elif op == "Argmax":
            best = 0
            for i, v in enumerate(x):
                if v > x[best]:
                    best = i
            return [len(x) + 1] + x + [best]


# ---- one case ---------------------------------------------------------------

def run_case(seed):
    d = os.path.join(OUT, str(seed))
    os.makedirs(d, exist_ok=True)
    g = random_graph(seed)
    json.dump(g, open(os.path.join(d, "model.json"), "w"))
    ops = "-".join(n["op"] for n in g["nodes"] if n["op"] not in ("Relu", "Flatten", "Argmax"))

    r = subprocess.run([COMPILER, "model.json"], cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        return seed, "REJECT", ops, (r.stderr.strip().splitlines() or ["?"])[-1]
    b = os.path.join(d, "build", g["model_name"])
    subprocess.run([ASSEMBLER, b + ".asm", b + ".hex"], cwd=d, capture_output=True, check=True)

    expect = [int(t, 16) for t in open(b + ".expect.hex").read().split()]
    ref = reference(g)
    if ref != expect:
        return seed, "FAIL", ops, f"compiler reference {expect} != graph reference {ref}"

    lines = lambda f: sum(1 for _ in open(f))
    try:
        r = subprocess.run(["vvp", "-n", SIM, f"+PROG={b}.hex", f"+DATA={b}.data.hex", f"+EXPECT={b}.expect.hex",
                            f"+PROG_WORDS={lines(b + '.hex')}", f"+DATA_BYTES={lines(b + '.data.hex')}",
                            f"+N_REPLY={len(expect)}", "+MAX_CYCLES=20000000"],
                           capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return seed, "FAIL", ops, "simulator wall-clock timeout"
    res = [l for l in r.stdout.splitlines() if l.startswith("RESULT") or l.startswith("  byte")]
    if res and res[-1].startswith("RESULT: PASS"):
        return seed, "PASS", ops, res[-1].split()[-1]
    return seed, "FAIL", ops, " | ".join(res) or r.stdout[-300:]


def main():
    args = sys.argv[1:]
    opt = lambda k, dflt: int(args[args.index(k) + 1]) if k in args else dflt
    n, seed0, jobs = opt("--n", 50), opt("--seed", 1), opt("--jobs", os.cpu_count() or 4)

    subprocess.run(["cargo", "build", "--quiet", "--bins"], cwd=HERE, check=True)
    subprocess.run(["iverilog", "-g2012", "-s", "tb", "-o", SIM, "test/tb_mlc.sv"] +
                   sorted(os.path.join("src", f) for f in os.listdir(os.path.join(ROOT, "src")) if f.endswith(".sv")),
                   cwd=ROOT, check=True, capture_output=True)

    counts = {"PASS": 0, "FAIL": 0, "REJECT": 0}
    with ThreadPoolExecutor(jobs) as pool:
        for seed, status, ops, info in pool.map(run_case, range(seed0, seed0 + n)):
            counts[status] += 1
            print(f"{status:6} seed {seed:<6} {ops:<34} {info}", flush=True)
            if status == "PASS" and "--keep" not in args:
                shutil.rmtree(os.path.join(OUT, str(seed)), ignore_errors=True)

    print(f"\n{counts['PASS']} passed, {counts['FAIL']} failed, {counts['REJECT']} rejected by the compiler")
    sys.exit(1 if counts["FAIL"] else 0)


if __name__ == "__main__":
    main()
