import os, termios, time, select, fcntl, struct, sys
PORT="/dev/cu.usbserial-20250303171"; IOSS=0x80045402
payload_path=sys.argv[1] if len(sys.argv)>1 else "/Users/joseignacio/tiny-gpu-fpga/software/mnist_data/fc_payload0.hex"
data=bytes(int(l.split("//")[0].strip(),16) for l in open(payload_path) if l.split("//")[0].strip())
print(f"payload: {len(data)} bytes (expect 3380)")
fd=os.open(PORT, os.O_RDWR|os.O_NOCTTY)
a=termios.tcgetattr(fd); a[0]=0;a[1]=0;a[3]=0
a[2]=termios.CS8|termios.CREAD|termios.CLOCAL
a[6][termios.VMIN]=0; a[6][termios.VTIME]=0
termios.tcsetattr(fd, termios.TCSANOW, a)
fcntl.ioctl(fd, IOSS, struct.pack('I', 115200))
termios.tcflush(fd, termios.TCIOFLUSH)
# stream payload in small chunks (no host flow control; FPGA RX is always ready)
for i in range(0, len(data), 64):
    os.write(fd, data[i:i+64]); time.sleep(0.002)
# read the 1-byte predicted digit
buf=b""; end=time.time()+5
while time.time()<end and not buf:
    r,_,_=select.select([fd],[],[],0.5)
    if r:
        d=os.read(fd,8)
        if d: buf+=d
os.close(fd)
if buf: print(f"predicted digit = {buf[0]}  (raw bytes: {[b for b in buf]})")
else:   print("no response")
