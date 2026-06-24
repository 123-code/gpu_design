#!/usr/bin/env python3
"""Measure real ALU ops/s of the GPU on hardware.

Runs bench_ops.hex at several OUTER loop counts (inner fixed). The program is
identical every run -- only mem[0] (outer) changes -- so wall-clock time is
  T(outer) = fixed_overhead(load+reply+ramp) + outer * t_per_outer
A linear fit of T vs outer gives t_per_outer, which is PURE GPU compute time
(all fixed UART/load overhead cancels in the slope). Then:
  ops/s = (inner * BODY_OPS * lanes_per_core * num_cores) / t_per_outer

  python3 bench_host.py [--port DEV]
"""
import os, termios, time, select, fcntl, struct, sys

PORT = "/dev/cu.usbserial-20250303171"
IOSS = 0x80045402
BAUD = 115200

BODY_OPS   = 16     # ALU ops in the inner-loop body (see bench_ops.asm)
LANES_CORE = 9      # active lanes per core (TPB=9)
NUM_CORES  = 2
INNER      = 200
OUTERS     = [40, 80, 120, 160, 200]
REPS       = 5      # take the min wall-clock per point (least OS jitter)
REPLY_N    = 4      # [1][m] from core0 then core1


def load_hex(path):
    out = []
    for line in open(path):
        s = line.split("//")[0].split(";")[0].strip()
        if s:
            out.append(int(s, 16) & 0xFFFF)
    return out


def open_port(port):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
    attr = termios.tcgetattr(fd); attr[0] = 0; attr[1] = 0; attr[3] = 0
    attr[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attr[6][termios.VMIN] = 0; attr[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    fcntl.ioctl(fd, IOSS, struct.pack('I', BAUD))
    return fd


def run_once(fd, prog, outer, inner):
    data = bytes([outer & 0xFF, inner & 0xFF, 0])      # mem[0]=outer, mem[1]=inner, +pad
    frame = bytearray()
    frame += struct.pack("<H", len(prog))
    frame += struct.pack("<H", len(data))
    for wd in prog:
        frame += bytes([wd & 0xFF, (wd >> 8) & 0xFF])
    frame += data
    termios.tcflush(fd, termios.TCIOFLUSH)
    t0 = time.perf_counter()
    for j in range(0, len(frame), 64):
        os.write(fd, frame[j:j + 64])
    buf = b""
    end = time.perf_counter() + 3.0
    while time.perf_counter() < end and len(buf) < REPLY_N:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            buf += os.read(fd, REPLY_N - len(buf))
    t1 = time.perf_counter()
    if len(buf) < REPLY_N:
        return None
    return t1 - t0


def main():
    port = PORT
    a = sys.argv[1:]
    if "--port" in a:
        port = a[a.index("--port") + 1]
    prog = load_hex(os.path.join(os.path.dirname(__file__), "bench_ops.hex"))
    fd = open_port(port)
    time.sleep(0.2)

    print(f"prog={len(prog)} words, inner={INNER}, body={BODY_OPS} ops, "
          f"lanes={LANES_CORE}x{NUM_CORES}")
    pts = []
    for outer in OUTERS:
        best = min(t for _ in range(REPS) if (t := run_once(fd, prog, outer, INNER)))
        pts.append((outer, best))
        print(f"  outer={outer:4d}  min wall-clock = {best*1e3:8.2f} ms")
    os.close(fd)

    # least-squares slope of T vs outer
    n = len(pts)
    sx = sum(o for o, _ in pts); sy = sum(t for _, t in pts)
    sxx = sum(o * o for o, _ in pts); sxy = sum(o * t for o, t in pts)
    slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)   # seconds per outer-iter
    intercept = (sy - slope * sx) / n

    ops_per_outer = INNER * BODY_OPS * LANES_CORE * NUM_CORES
    ops_s = ops_per_outer / slope
    print(f"\nfixed overhead (intercept) = {intercept*1e3:.2f} ms")
    print(f"time per outer-iter (slope) = {slope*1e6:.2f} us")
    print(f"ALU ops per outer-iter      = {ops_per_outer}")
    print(f"==> MEASURED ALU throughput = {ops_s/1e6:.1f} M ops/s")


if __name__ == "__main__":
    main()
