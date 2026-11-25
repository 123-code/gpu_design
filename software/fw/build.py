#!/usr/bin/env python3
"""Build the host-CPU firmware: kernel.hex -> kernel.c, clang rv32i -> fw.hex.

    python3 fw/build.py <gpu_kernel.hex> <out.hex>
"""
import os, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
khex, out = sys.argv[1], sys.argv[2]
words = [int(l, 16) for l in open(khex).read().split()]
bdir = os.path.dirname(os.path.abspath(out))
kc = os.path.join(bdir, "fw_kernel.c")
with open(kc, "w") as f:
    f.write("#include <stdint.h>\n")
    f.write("const uint16_t kernel[] = {" + ", ".join(f"0x{w:04x}" for w in words) + "};\n")
    f.write(f"const int kernel_len = {len(words)};\n")
elf = os.path.join(bdir, "fw.elf")
subprocess.check_call(["clang", "--target=riscv32", "-march=rv32i", "-mabi=ilp32", "-O2",
                       "-ffreestanding", "-nostdlib", "-fno-builtin", "-T", os.path.join(here, "link.ld"),
                       os.path.join(here, "start.S"), os.path.join(here, "host.c"), kc,
                       "-fuse-ld=lld", "-o", elf])
binf = elf + ".bin"
subprocess.check_call(["llvm-objcopy", "-O", "binary", elf, binf])
data = open(binf, "rb").read()
data += bytes(-len(data) % 4)
with open(out, "w") as f:
    for i in range(0, len(data), 4):
        f.write(f"{int.from_bytes(data[i:i+4], 'little'):08x}\n")
print(f"firmware: {len(data)} bytes -> {out}")
