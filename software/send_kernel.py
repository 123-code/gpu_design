#!/usr/bin/env python3
"""Load an arbitrary kernel onto the GPU over UART, run it, read the reply.

  python3 send_kernel.py <kernel.hex> [d0,d1,d2,...] [--read N] [--port DEV]

Streams the header-driven frame the current data_pipeline DMA expects (same
protocol as test/tb_loadrun.sv):

    header : instr_size (16-bit WORDS, LE) | data_size (bytes, LE)
    program: each 16-bit word low byte then high byte
    data   : raw payload bytes (broadcast into BOTH cores' memory)

The DMA loads the program into instruction RAM and the data into memory, then
starts the GPU. Each core emits whatever the kernel frames (the demo convention
is [len][bytes...]); we print the raw reply bytes, core 0 then core 1.

macOS note: FTDI baud must be set with the IOSSIOSPEED ioctl — stty/termios
silently leave the port at 9600 (lifted from send_mnist.py).
"""
import os, termios, time, select, fcntl, struct, sys

PORT = "/dev/cu.usbserial-20250303171"   # higher-numbered port = FTDI iface 1 = UART
IOSS = 0x80045402
BAUD = 115200


def load_hex(path):
    words = []
    for line in open(path):
        s = line.split("//")[0].split(";")[0].strip()
        if s:
            words.append(int(s, 16) & 0xFFFF)
    return words


def main():
    args = [a for a in sys.argv[1:]]
    read_n = 16
    port = PORT
    # pull options
    rest = []
    i = 0
    while i < len(args):
        if args[i] == "--read":
            read_n = int(args[i + 1]); i += 2
        elif args[i] == "--port":
            port = args[i + 1]; i += 2
        else:
            rest.append(args[i]); i += 1

    if not rest:
        print("usage: send_kernel.py <kernel.hex> [d0,d1,...] [--read N] [--port DEV]")
        sys.exit(2)

    kernel = rest[0]
    data = bytes(int(x, 0) & 0xFF for x in rest[1].split(",")) if len(rest) > 1 and rest[1] else b""

    prog = load_hex(kernel)
    instr_size = len(prog)
    data_size = len(data)

    frame = bytearray()
    frame += struct.pack("<H", instr_size)          # header: instr_size LE
    frame += struct.pack("<H", data_size)           #         data_size LE
    for w in prog:                                  # program: low byte then high byte
        frame += bytes([w & 0xFF, (w >> 8) & 0xFF])
    frame += data                                   # data payload

    print(f"kernel {os.path.basename(kernel)}: {instr_size} words, {data_size} data bytes "
          f"-> {len(frame)} frame bytes on {port}")

    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
    attr = termios.tcgetattr(fd); attr[0] = 0; attr[1] = 0; attr[3] = 0
    attr[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attr[6][termios.VMIN] = 0; attr[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attr)
    fcntl.ioctl(fd, IOSS, struct.pack('I', BAUD))
    termios.tcflush(fd, termios.TCIOFLUSH)

    for j in range(0, len(frame), 64):              # no host flow control; FPGA RX always ready
        os.write(fd, frame[j:j + 64]); time.sleep(0.002)

    buf = b""; end = time.time() + 5
    while time.time() < end and len(buf) < read_n:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            d = os.read(fd, read_n)
            if d:
                buf += d; end = time.time() + 0.5   # extend a bit after each chunk
    os.close(fd)

    print(f"reply ({len(buf)} bytes): " + " ".join(f"{b:02x}" for b in buf))
    print(f"           decimal     : " + " ".join(f"{b:>3d}" for b in buf))


if __name__ == "__main__":
    main()
