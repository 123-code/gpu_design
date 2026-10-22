#!/usr/bin/env python3
"""Wolfenstein-style raycaster on tiny-gpu. The GPU (raycast.jpp) renders; this
script is the game (keyboard, movement, collision). The picture goes out of the
board's HDMI port (src/hdmi.sv) and is mirrored in the terminal.

  python3 raycast.py               play on the board (w/s move, a/d turn, q quits)
  python3 raycast.py --spin S      turn on the spot for S seconds, no keyboard needed
  python3 raycast.py --ref         play with the Python reference as the renderer (no board)
  python3 raycast.py --check N     N random poses on the board vs the reference, bit-exact
  python3 raycast.py --sim         write build/raycast.*.hex for test/tb_raycast.sv
  --threads N                      lanes per core of the loaded bitstream (default 9)

Frame 0 streams the kernel, tables and map. Every later frame sends only the
7-byte pose (DMA header instr_size = 0, so the program and tables stay put).
Core 0 renders the left half of the screen and core 1 the right; each replies
with a length byte, then one byte per column: half the wall's height in pixels
on the 640x480 HDMI picture (0..240).

Every number in the memory map is mirrored in raycast.jpp; `make sim-raycast`
fails if the two drift apart.
"""
import math, os, random, select, sys, termios, time, tty

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mnist_ref import load_hex
from run_mnist_jpp import frame, open_uart, run_one   # UART framing + macOS FTDI baud setup

KERNEL = os.path.join(HERE, "raycast.hex")

# ---- memory map: core-private 8 KB, mirrored in raycast.jpp ----
#   0..1 px   2..3 py + MAP*4   4 pa   5 wave counter (0 every frame)   6 pad
#   63 is the UART: nothing may be stored there
WAVES  = 4              # columns = WAVES * 2 cores * threads
RES    = 64             # per-core results, packed as wave*bdim + tid
COLTAB = 128            # per-column ray angle offset + BIAS, in 1/512 turns
FISH   = 256            # per-column 255*cos(offset): fisheye correction
HTAB   = 384            # perpendicular distance in steps -> half wall height in pixels
TX     = 640            # 128 + STEP*cos(a), a in 1/512 turns, biased by BIAS
TY     = 1238           # 128 + STEP*sin(a)
MAP    = 2048           # 16 rows at stride 256: ((y>>10)<<8) + (x>>10) is the address
FRAC   = 10             # positions are 6.10 fixed point
STEP   = 127            # march step = 127/1024 cell, so dx/dy fit a byte
STEPS  = 168            # enough to cross the map diagonally
BIAS   = 43             # widest column offset, keeps COLTAB unsigned
NA     = 512 + 2 * BIAS # TX/TY entries: 2*pa + COLTAB reaches 510 + 86

ROWS, FOV = 24, 60.0
SHADES = "█▓▒░"
START = (1.5, 8.5, 0)      # x, y in cells, pa in 1/256 turns (0 = facing east, down the corridor)

LEVEL = [
    "################",
    "#..............#",
    "#..##......##..#",
    "#..#........#..#",
    "#......##......#",
    "#......##......#",
    "#..............#",
    "####..####..####",
    "#..............#",
    "#.#.#.#..#.#.#.#",
    "#..............#",
    "#....######....#",
    "#....#....#....#",
    "#..............#",
    "#..............#",
    "################",
]


def tables(threads):
    w = WAVES * 2 * threads
    assert WAVES * threads <= COLTAB - RES and w <= FISH - COLTAB, "too many columns for the memory map"
    half = math.tan(math.radians(FOV) / 2)
    turn = lambda a: (a - BIAS) * 2 * math.pi / 512
    # atan spacing = a flat projection plane, so straight walls stay straight
    col = [round(math.atan((2 * (c + 0.5) / w - 1) * half) * 512 / (2 * math.pi)) + BIAS for c in range(w)]
    fish = [min(255, round(255 * math.cos(turn(a)))) for a in col]
    k = 2 * w / half                       # half height of a 1-cell wall 1 cell away, in pixels
    # (HDMI draws each column 8 px wide, so the focal length is 4w / tan(FOV/2))
    htab = [240] + [min(240, round(k * 1024 / (STEP * p))) for p in range(1, 256)]
    tx = [128 + round(STEP * math.cos(turn(a))) for a in range(NA)]
    ty = [128 + round(STEP * math.sin(turn(a))) for a in range(NA)]
    return col, fish, htab, tx, ty


def state(pose):
    x, y, a = pose
    px, py = round(x * 1024), round(y * 1024) + MAP * 4
    return bytes([px & 255, px >> 8, py & 255, py >> 8, a, 0, 0])   # wave = 0, pad (the DMA drops it)


def image(threads, pose):
    """Everything frame 0 streams into both cores' memory."""
    col, fish, htab, tx, ty = tables(threads)
    mem = bytearray(MAP + 15 * 256 + 16)
    mem[0:7] = state(pose)
    mem[COLTAB:COLTAB + len(col)] = bytes(col)
    mem[FISH:FISH + len(fish)] = bytes(fish)
    mem[HTAB:HTAB + 256] = bytes(htab)
    mem[TX:TX + NA] = bytes(tx)
    mem[TY:TY + NA] = bytes(ty)
    for r, row in enumerate(LEVEL):
        mem[MAP + 256 * r:MAP + 256 * r + 16] = bytes(c == "." for c in row)   # 1 = empty, 0 = wall
    return mem


def ref_columns(mem, threads):
    """Bit-exact model of raycast.jpp: one byte per screen column, left to right."""
    out = []
    for c in range(WAVES * 2 * threads):
        a = 2 * mem[4] + mem[COLTAB + c]
        dx, dy = (mem[TX + a] - 128) & 0xFFFF, (mem[TY + a] - 128) & 0xFFFF
        x, y, d = mem[0] | mem[1] << 8, mem[2] | mem[3] << 8, 0
        for _ in range(STEPS):
            cell = mem[((y >> FRAC) << 8) + (x >> FRAC)]   # 0 once the ray is inside a wall
            dx, dy, d = dx * cell & 0xFFFF, dy * cell & 0xFFFF, d + cell
            x, y = (x + dx) & 0xFFFF, (y + dy) & 0xFFFF
        out.append(mem[HTAB + (((d * mem[FISH + c]) & 0xFFFF) >> 8)])
    return out


def reply_for(cols, threads):
    """Core 0 (left half) then core 1 (right half), each behind a length byte."""
    n = WAVES * threads
    return [n] + cols[:n] + [n] + cols[n:]


def cols_from_reply(reply, threads):
    n = WAVES * threads
    if len(reply) != 2 * (n + 1) or reply[0] != n or reply[n + 1] != n:
        return None
    return reply[1:n + 1] + reply[n + 2:]


def draw(cols, status):
    lines = []
    for r in range(ROWS):
        line = ""
        for h in cols:
            rh = round(h * ROWS / 480)     # 240 px half height = ROWS / 2 rows
            wall = ROWS // 2 - rh <= r < ROWS // 2 + rh
            line += SHADES[0 if h >= 120 else 1 if h >= 60 else 2 if h >= 30 else 3] if wall \
                else " " if r < ROWS // 2 else "."
        lines.append(line)
    sys.stdout.write("\x1b[H" + "\n".join(lines) + "\n" + status + "\x1b[K")
    sys.stdout.flush()


def blocked(x, y, r=0.25):
    """Keep a body radius around the camera so it never stands inside a wall."""
    return any(LEVEL[int(y + oy)][int(x + ox)] == "#" for ox in (-r, r) for oy in (-r, r))


def move(pose, key):
    x, y, a = pose
    if key in "ad":
        return x, y, (a + (4 if key == "d" else -4)) % 256
    if key in "ws":
        th, v = a * 2 * math.pi / 256, 0.2 if key == "w" else -0.2
        nx, ny = x + v * math.cos(th), y + v * math.sin(th)
        x = x if blocked(nx, y) else nx       # axis by axis: slide along walls
        y = y if blocked(x, ny) else ny
    return x, y, a


class Board:
    """Frame 0 loads kernel + tables + map; later frames send only the pose."""
    def __init__(self, threads):
        self.threads, self.n = threads, 2 * (WAVES * threads + 1)
        self.fd = open_uart()
        time.sleep(0.2); termios.tcflush(self.fd, termios.TCIOFLUSH)
        self.loaded = False

    def columns(self, pose):
        if self.loaded:
            fr = frame([], state(pose))
        else:
            fr = frame(load_hex(KERNEL), bytes(image(self.threads, pose)) + b"\x00")
        reply, _ = run_one(self.fd, fr, n_reply=self.n, timeout=10.0 if not self.loaded else 2.0)
        self.loaded = True
        cols = cols_from_reply(list(reply), self.threads)
        if cols is None:
            termios.tcflush(self.fd, termios.TCIOFLUSH)
            raise SystemExit(f"bad reply ({len(reply)}/{self.n} bytes) - reflash the bitstream and retry")
        return cols


def random_pose():
    while True:
        x, y = random.uniform(1.3, 14.7), random.uniform(1.3, 14.7)
        if not blocked(x, y):
            return x, y, random.randrange(256)


def check(n, threads):
    board, mem, bad = Board(threads), image(threads, START), 0
    t0 = time.time()
    for i in range(n):
        pose = START if i == 0 else random_pose()
        mem[0:7] = state(pose)
        chip, ref = board.columns(pose), ref_columns(mem, threads)
        bad += chip != ref
        print(f"pose {i:3d}  x={pose[0]:5.2f} y={pose[1]:5.2f} a={pose[2]:3d}  "
              f"{'OK' if chip == ref else 'MISMATCH'}", flush=True)
        if i == 0:
            t0 = time.time()                   # don't count the one-off load in the frame rate
    print(f"\nchip == reference on {n - bad}/{n} poses, {(n - 1) / (time.time() - t0):.1f} frames/s")
    sys.exit(1 if bad else 0)


def spin(seconds, threads):
    """Turn on the spot so the HDMI picture moves without a keyboard."""
    board, pose, n, t0 = Board(threads), START, 0, time.time()
    while time.time() - t0 < seconds:
        board.columns(pose)
        pose, n = (pose[0], pose[1], (pose[2] + 1) % 256), n + 1
    print(f"{n} frames, {n / (time.time() - t0):.1f} frames/s")


def play(render):
    pose, old = START, termios.tcgetattr(sys.stdin)
    tty.setcbreak(sys.stdin.fileno())
    sys.stdout.write("\x1b[2J\x1b[?25l")
    try:
        frames, t0 = 0, time.time()
        while True:
            while select.select([sys.stdin], [], [], 0)[0]:
                k = sys.stdin.read(1)
                if k == "q":
                    return
                pose = move(pose, k)
            cols = render(pose)
            frames += 1
            draw(cols, f"x={pose[0]:5.2f} y={pose[1]:5.2f} a={pose[2]:3d}  "
                       f"{frames / (time.time() - t0):4.1f} fps   w/s move  a/d turn  q quit")
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old)
        sys.stdout.write("\x1b[?25h\n")


def sim(threads):
    """Two frames for tb_raycast.sv: a full load, then a pose-only frame."""
    out = os.path.join(HERE, "build"); os.makedirs(out, exist_ok=True)
    pose2 = (3.25, 8.5, 37)
    mem = image(threads, START)
    data, frame2 = bytes(mem) + b"\x00", state(pose2)
    want1 = reply_for(ref_columns(mem, threads), threads)
    mem[0:7] = frame2
    want2 = reply_for(ref_columns(mem, threads), threads)
    files = {"data": data, "frame2": frame2, "expect1": want1, "expect2": want2,
             "sizes": [len(load_hex(KERNEL)), len(data), len(frame2), len(want1)]}
    for name, vals in files.items():
        with open(os.path.join(out, f"raycast.{name}.hex"), "w") as f:
            f.writelines(f"{v:04X}\n" if name == "sizes" else f"{v:02X}\n" for v in vals)
    print(f"sim: {files['sizes'][0]} program words, {len(data)} data bytes, {len(want1)} reply bytes per frame")


def main():
    args = sys.argv[1:]
    threads = int(args[args.index("--threads") + 1]) if "--threads" in args else 9
    if "--sim" in args:
        sim(threads)
    elif "--spin" in args:
        spin(float(args[args.index("--spin") + 1]), threads)
    elif "--check" in args:
        check(int(args[args.index("--check") + 1]), threads)
    elif "--ref" in args:
        mem = image(threads, START)
        def render(pose):
            mem[0:7] = state(pose)
            return ref_columns(mem, threads)
        play(render)
    else:
        play(Board(threads).columns)


if __name__ == "__main__":
    main()
