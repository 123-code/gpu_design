#!/usr/bin/env python3
"""Tiny stdlib web server bridging a drawing canvas to the tiny-gpu FPGA.

  GET  /          -> the drawing page (demo/index.html)
  POST /predict   -> body {"pixels":[784 ints 0..255]}; streams the 28x28 image to
                     the board over UART (to both cores), returns {"digit": N, "ms": T}

Reuses the macOS IOSSIOSPEED baud trick (plain stty/termios silently stay at 9600).
Run:  python3 demo/server.py        then open  http://localhost:8000
Override the UART port with:  PORT=/dev/cu.usbserial-XXXX python3 demo/server.py
"""
import os, sys, glob, json, time, select, termios, fcntl, struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SOFTWARE = os.path.join(os.path.dirname(HERE), "software")
sys.path.insert(0, SOFTWARE)
from mnist_ref import run_pipeline, load_model   # bit-exact stage model

IOSS = 0x80045402  # macOS TIOCSIOSPEED-equivalent: set arbitrary baud
WEIGHTS, BIASES = load_model()  # baked CNN weights/biases, loaded once

def find_port():
    if os.environ.get("PORT"):
        return os.environ["PORT"]
    ports = sorted(glob.glob("/dev/cu.usbserial-*"))
    if not ports:
        raise RuntimeError("no /dev/cu.usbserial-* found — is the board plugged in?")
    return ports[-1]          # higher-numbered = FTDI interface 1 = the UART side

def classify(pixels):
    """Send the drawn image to BOTH cores (2 x 784 bytes), return
    (digit, ms): core 0's prediction and its run time in milliseconds.
    Reply protocol: [digit0][cycles0 x3][digit1][cycles1 x3] = 8 bytes."""
    port = find_port()
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
    try:
        a = termios.tcgetattr(fd); a[0]=0; a[1]=0; a[3]=0
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[6][termios.VMIN] = 0; a[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, a)
        fcntl.ioctl(fd, IOSS, struct.pack('I', 115200))
        termios.tcflush(fd, termios.TCIOFLUSH)
        # drain any stale bytes from a previous (aborted) run
        end = time.time() + 0.3
        while time.time() < end:
            r,_,_ = select.select([fd], [], [], 0.1)
            if r: os.read(fd, 64); end = time.time() + 0.15
        # stream the image twice: core 0's copy, then core 1's copy
        img = bytes(max(0, min(255, int(p))) for p in pixels)
        data = img + img
        for i in range(0, len(data), 64):
            os.write(fd, data[i:i+64]); time.sleep(0.002)
        # read the 8-byte reply (GPU runs ~18 ms then emits)
        buf = b""; end = time.time() + 5
        while time.time() < end and len(buf) < 8:
            r,_,_ = select.select([fd], [], [], 0.3)
            if r:
                d = os.read(fd, 8)
                if d: buf += d
        if len(buf) < 8:
            return (buf[0], None, None) if buf else (None, None, None)
        cycles0 = (buf[1] << 16) | (buf[2] << 8) | buf[3]
        return buf[0], round(cycles0 / 27_000_000 * 1000, 2), cycles0  # 27 MHz clock
    finally:
        os.close(fd)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype="application/json"):
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                self._send(200, f.read(), "text/html; charset=utf-8")
        elif self.path == "/health":
            # the page probes this to choose Live vs Gallery mode
            try:
                port = find_port(); ok = True
            except Exception:
                port = None; ok = False
            self._send(200, json.dumps({"board": ok, "port": port}).encode())
        elif self.path.startswith("/recordings/"):
            # serve the captured gallery runs as static files
            rel = self.path.lstrip("/").split("?")[0]
            fpath = os.path.join(HERE, *rel.split("/"))
            if os.path.isfile(fpath):
                with open(fpath, "rb") as f:
                    self._send(200, f.read(), "application/json")
            else:
                self._send(404, b'{"error":"not found"}')
        else:
            self._send(404, b"not found", "text/plain")
    def do_POST(self):
        if self.path != "/predict":
            return self._send(404, b'{"error":"not found"}')
        try:
            n = int(self.headers.get("Content-Length", 0))
            pixels = json.loads(self.rfile.read(n))["pixels"]
            if len(pixels) != 784:
                raise ValueError(f"expected 784 pixels, got {len(pixels)}")
            d, ms, cycles = classify(pixels)                      # digit + timing from silicon
            stages = run_pipeline([int(p) & 0xFF for p in pixels],  # bit-exact stage maps
                                  WEIGHTS, BIASES)
            self._send(200, json.dumps({
                "digit": d, "ms": ms, "cycles": cycles,
                "conv": stages["conv"], "pooled": stages["pooled"],
                "scores": stages["scores"], "ref_pred": stages["pred"],
            }).encode())
        except Exception as e:
            self._send(500, json.dumps({"error": str(e)}).encode())

if __name__ == "__main__":
    try:
        print("UART port:", find_port())
    except Exception as e:
        print("warning:", e)
    print("open http://localhost:8000  (Ctrl-C to stop)")
    ThreadingHTTPServer(("127.0.0.1", 8000), H).serve_forever()
