#!/usr/bin/env python3
"""Capture tiny-gpu runs into static JSON for the demo Gallery (no board needed
to *view* them later — they're replayed by demo/index.html as a static page).

  python3 demo/record.py                 # curated 0-9 spread from the bundled batch
  python3 demo/record.py 0 7 30          # specific image indices
  python3 demo/record.py img.hex ...     # explicit 784-byte hex files
  python3 demo/record.py --offline ...   # don't touch the board (reference digit only)

With the Tang Nano attached, each run streams the image to the FPGA and stores the
*real* predicted digit + on-chip cycle count/timing, plus the bit-exact reference
stage maps (conv/pool/FC). Without a board (or --offline) it stores the stages and
the reference digit, with timing left null. Writes demo/recordings/*.json and
recordings/index.json (the gallery index).
"""
import os, sys, json

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DATA = os.path.join(ROOT, "software", "mnist_data")
OUT  = os.path.join(HERE, "recordings")
sys.path.insert(0, os.path.join(ROOT, "software"))
sys.path.insert(0, HERE)

from mnist_ref import run_pipeline, load_model, load_hex, load_labels

# curated spread of bundled-batch indices, one per available digit class (no clean 8)
CURATED = [3, 2, 1, 30, 4, 8, 11, 0, 7]   # -> digits 0,1,2,3,4,5,6,7,9

def board_classify(pixels):
    """Return (digit, ms, cycles) from the real FPGA, or None if unavailable."""
    try:
        import server   # reuses the demo server's single-image UART round-trip
        return server.classify(pixels)
    except Exception as e:
        print(f"  (board unavailable: {e})")
        return None

def resolve(arg):
    """Map a CLI arg to (name, 784-pixel list). Accepts an index or a .hex path."""
    if arg.endswith(".hex"):
        path = arg if os.path.isabs(arg) else os.path.join(os.getcwd(), arg)
        return os.path.splitext(os.path.basename(arg))[0], load_hex(path)
    idx = int(arg)
    hexp = os.path.join(DATA, f"image{idx}.hex")
    if not os.path.isfile(hexp):
        # materialise image{idx}.hex via the reference dumper
        os.system(f'cd "{os.path.join(ROOT,"software")}" && python3 mnist_ref.py {idx} >/dev/null')
    return f"idx{idx}", load_hex(hexp), idx

def main():
    args = sys.argv[1:]
    offline = "--offline" in args
    args = [a for a in args if a != "--offline"]
    items = args if args else [str(i) for i in CURATED]

    weights, biases = load_model()
    labels = load_labels(os.path.join(DATA, "images_batch.hex"))
    os.makedirs(OUT, exist_ok=True)

    runs = []
    for arg in items:
        r = resolve(arg); name, pixels = r[0], r[1]
        idx = r[2] if len(r) > 2 else None
        assert len(pixels) == 784, f"{name}: expected 784 px, got {len(pixels)}"
        st = run_pipeline(pixels, weights, biases)

        digit, ms, cycles = st["pred"], None, None
        if not offline:
            got = board_classify(pixels)
            if got: digit, ms, cycles = got

        rec = {"input": pixels, "conv": st["conv"], "pooled": st["pooled"],
               "scores": st["scores"], "ref_pred": st["pred"],
               "digit": digit, "ms": ms, "cycles": cycles,
               "label": labels.get(idx) if idx is not None else None,
               "source": "fpga" if ms is not None else "reference"}
        fname = f"{name}_d{st['pred']}.json"
        with open(os.path.join(OUT, fname), "w") as f:
            json.dump(rec, f)
        runs.append({"file": fname, "digit": st["pred"], "label": rec["label"]})
        tail = f"{ms} ms on-chip" if ms is not None else "reference only (no board)"
        print(f"  {name}: digit {st['pred']}  [{tail}]  -> recordings/{fname}")

    with open(os.path.join(OUT, "index.json"), "w") as f:
        json.dump({"runs": runs}, f, indent=1)
    print(f"wrote {len(runs)} runs + index.json into demo/recordings/")

if __name__ == "__main__":
    main()
