#!/usr/bin/env python3
"""Run the J++ MNIST model (mnist.jpp) on the FPGA and check every prediction
against the bit-exact reference (mnist_ref.py).

  python3 run_mnist_jpp.py [N]          board: classify test images 0..N-1 (default 50)
  python3 run_mnist_jpp.py --sim IDX    write build/ payload + expected files for tb_mnist_jpp_full.sv

Data payload, matching the memory map at the top of mnist.jpp:
  image (784) | zeros: conv + pooled maps the GPU writes + 32 spare (877) | dense weights (1690) | 1 pad
(the pad absorbs the byte the DMA drops at the end of a frame). The kernel emits
one byte per core: its predicted digit.
"""
import os, sys, time, select, termios, fcntl, struct

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mnist_ref import load_hex, load_labels, load_model, run_pipeline, DATA

KERNEL = os.path.join(HERE, "mnist_jpp.hex")
PORT = os.environ.get("PORT", "/dev/cu.usbserial-20250303171")  # *1 = UART side
IOSS = 0x80045402  # macOS: stty/termios silently stay at 9600, set the baud with this ioctl
MAPS = 676 + 169 + 32   # conv map + pooled map + spare gap, all written by the GPU


def payload(img, weights):
    return bytes(img) + bytes(MAPS) + bytes(weights[9:9 + 1690]) + b"\x00"


def frame(prog, data):
    f = bytearray(struct.pack("<HH", len(prog), len(data)))
    for w in prog:
        f += bytes([w & 0xFF, w >> 8])
    return f + data


def open_uart():
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY)
    a = termios.tcgetattr(fd); a[0] = 0; a[1] = 0; a[3] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[6][termios.VMIN] = 0; a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    fcntl.ioctl(fd, IOSS, struct.pack("I", 115200))
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def run_one(fd, fr, n_reply=2, timeout=5.0):
    for j in range(0, len(fr), 64):
        os.write(fd, fr[j:j + 64]); time.sleep(0.002)
    t0 = time.time(); buf = b""
    while time.time() - t0 < timeout and len(buf) < n_reply:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            buf += os.read(fd, n_reply - len(buf))
    return buf, time.time() - t0


def main():
    prog = load_hex(KERNEL)
    weights, biases = load_model()
    imgs_path = os.path.join(DATA, "images_batch.hex")
    imgs, labels = load_hex(imgs_path), load_labels(imgs_path)

    if sys.argv[1:2] == ["--sim"]:
        idx = int(sys.argv[2])
        img = imgs[idx * 784:(idx + 1) * 784]
        ref = run_pipeline(img, weights, biases)
        out = os.path.join(HERE, "build")
        with open(os.path.join(out, "mnist_jpp.data.hex"), "w") as f:
            f.writelines(f"{b:02X}\n" for b in payload(img, weights))
        with open(os.path.join(out, "mnist_jpp.conv.hex"), "w") as f:
            f.writelines(f"{b:02X}\n" for b in ref["conv"])
        with open(os.path.join(out, "mnist_jpp.pool.hex"), "w") as f:
            f.writelines(f"{b:02X}\n" for b in ref["pooled"])
        with open(os.path.join(out, "mnist_jpp.expect.hex"), "w") as f:
            f.write(f"{ref['pred']:02X}\n")
        print(f"sim image {idx}: {len(prog)} words, {len(payload(img, weights))} data bytes, reference predicts {ref['pred']}")
        return

    n = int(sys.argv[1]) if len(sys.argv) > 1 else 50
    fd = open_uart()
    time.sleep(0.2); termios.tcflush(fd, termios.TCIOFLUSH)
    match = correct = 0
    try:
        for idx in range(n):
            img = imgs[idx * 784:(idx + 1) * 784]
            ref = run_pipeline(img, weights, biases)["pred"]
            reply, secs = run_one(fd, frame(prog, payload(img, weights)))
            chip = list(reply)
            ok = len(chip) == 2 and chip[0] == ref and chip[1] == ref
            match += ok
            correct += len(chip) == 2 and chip[0] == labels.get(idx)
            print(f"image {idx:2d}  label {labels.get(idx)}  reference {ref}  chip {chip}  "
                  f"{secs:.2f}s  {'OK' if ok else 'MISMATCH'}", flush=True)
            time.sleep(0.3)  # pace the BL616 USB bridge
    finally:
        os.close(fd)
    print(f"\nchip == reference on {match}/{n} images (both cores); "
          f"chip correct vs label on {correct}/{n}")
    sys.exit(0 if match == n else 1)


if __name__ == "__main__":
    main()
