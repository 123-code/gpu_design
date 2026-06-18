#!/usr/bin/env python3
"""Stream TWO MNIST images to the dual-core GPU and read back both predictions.

  python3 send_mnist.py [imageA.hex] [imageB.hex]

Image A goes to core 0's memory copy, image B to core 1's; the cores classify
them concurrently. Reply: [digit0][cycles0 x3][digit1][cycles1 x3] = 8 bytes,
cycle counts 24-bit MSB-first at 27 MHz.

macOS note: baud must be set with the IOSSIOSPEED ioctl — stty/termios silently
leave FTDI ports at 9600.
"""
import os, termios, time, select, fcntl, struct, sys

PORT = "/dev/cu.usbserial-20250303171"
IOSS = 0x80045402
CLK_HZ = 27_000_000
DATA_DIR = "/Users/joseignacio/tiny-gpu-fpga/software/mnist_data"

def load_hex(path):
    return bytes(int(l.split("//")[0].strip(), 16)
                 for l in open(path) if l.split("//")[0].strip())

img_a = sys.argv[1] if len(sys.argv) > 1 else f"{DATA_DIR}/image1.hex"
img_b = sys.argv[2] if len(sys.argv) > 2 else f"{DATA_DIR}/image0.hex"
a, b = load_hex(img_a), load_hex(img_b)
assert len(a) == 784 and len(b) == 784, f"expected 784-byte images, got {len(a)}/{len(b)}"
data = a + b
print(f"core 0 <- {os.path.basename(img_a)}   core 1 <- {os.path.basename(img_b)}")

fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY)
attr = termios.tcgetattr(fd); attr[0]=0; attr[1]=0; attr[3]=0
attr[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
attr[6][termios.VMIN] = 0; attr[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, attr)
fcntl.ioctl(fd, IOSS, struct.pack('I', 115200))
termios.tcflush(fd, termios.TCIOFLUSH)

# stream both images in small chunks (no host flow control; FPGA RX is always ready)
for i in range(0, len(data), 64):
    os.write(fd, data[i:i+64]); time.sleep(0.002)

# read the 8-byte reply
buf = b""; end = time.time() + 5
while time.time() < end and len(buf) < 8:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        d = os.read(fd, 8)
        if d: buf += d
os.close(fd)

if len(buf) < 8:
    print(f"incomplete reply ({len(buf)} bytes): {[x for x in buf]}")
    sys.exit(1)

c0 = (buf[1] << 16) | (buf[2] << 8) | buf[3]
c1 = (buf[5] << 16) | (buf[6] << 8) | buf[7]
print(f"core 0: digit {buf[0]}   {c0} cycles = {c0/CLK_HZ*1000:.2f} ms")
print(f"core 1: digit {buf[4]}   {c1} cycles = {c1/CLK_HZ*1000:.2f} ms (incl. wait for core 0's UART bytes)")
print(f"-> 2 images classified concurrently in {max(c0,c1)/CLK_HZ*1000:.2f} ms")
