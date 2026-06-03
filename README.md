# tiny-gpu on the Tang Nano 20K

A small SIMT GPU core in SystemVerilog, with a Rust assembler, simulated with
Icarus Verilog and synthesized to a **Sipeed Tang Nano 20K** (Gowin GW2AR-18C).
The demo kernel computes `5 * 3 = 15` by repeated addition and shows the result
on the onboard LEDs.

## Status

- ✅ Simulation passes (`R3 = 15`, core reaches `DONE`).
- ✅ Synthesizes and runs on real hardware — the LED demo lights up.
- ✅ **UART multiply verified on hardware** (ASCII operand-injection build):
  `7 6` → `042`, `5 3` → `015`, `12 5` → `060`, `9 9` → `081`, `63 4` → `252`.
  This build clocks the GPU at **~13 kHz** (see Notes).
- ✅ The newer **host-driven DMA** build closes timing at the full **27 MHz**
  (0 setup / 0 hold violations, Fmax ≈ 97.6 MHz) — see Synthesis below.

> **Two `top.sv` variants exist** (the repo is mid-transition):
> 1. **ASCII operand-injection** — type `7 6`, get `042` back; operands patched
>    into the ROM; GPU on a ~13 kHz divided clock. *This is the one verified on
>    hardware* (and the one the Serial I/O section below describes).
> 2. **Host-driven DMA** — raw bytes streamed `UART → DMA → memory`, GPU reads via
>    `LDR`, runs at full 27 MHz. This is what the Gowin IDE project builds
>    (`GowinIDE.app/.../IDE/bin/gpu/`, `build_uart.tcl` → `impl/pnr/gpu_uart.fs`);
>    the `*.sh`/`*.tcl` here are a headless mirror — keep their source list in sync.

## Synthesis & utilization (Tang Nano 20K · GW2AR-18C)

From the post-place&route report (`impl/pnr/gpu_uart.rpt.html`) of the
**host-driven DMA** build:

| Resource              | Used                              | Available | Util. |
|-----------------------|-----------------------------------|-----------|-------|
| Logic (LUT+ALU+ROM16) | 1221 (900 LUT4, 321 ALU, 0 ROM16) | 20736     | 6 %   |
| Registers             | 819 (818 FF + 1 I/O)              | 15750     | 6 %   |
| CLS (slices)          | 1058                              | 10368     | 11 %  |
| Block SRAM (SDPB)     | 1                                 | 46        | 3 %   |
| DSP                   | 4× MULT9X9 + 5× MULTADDALU18X18   | —         | 25 %  |
| I/O ports             | 9                                 | 66        | 14 %  |
| PLL                   | 0                                 | 2         | 0 %   |

**Timing:** 27 MHz constraint (37.037 ns) — **Actual Fmax 97.6 MHz**, 0 setup
violations, 0 hold violations (TNS 0.000 on both). ~3.6× frequency headroom.
The DSPs are the 3×3 MAC convolution coprocessor; everything else is the SIMT
core, the 4-way LSU arbiter, and the UART/DMA host pipeline.

## Layout

```
src/        SystemVerilog: gpu, core, scheduler, decoder, registers, alu, pc, lsu, ...
            top.sv          board top-level (LED demo + UART result reporting)
            uart_tx.sv      115200 8N1 UART transmitter
            uart_rx.sv      115200 8N1 UART receiver
            gpu.cst         Tang Nano 20K pin constraints
            gpu.sdc         27 MHz timing constraint
software/   Rust assembler (src/main.rs) + kernel (test_kernel.asm -> kernel.hex)
test/       tb.sv self-checking testbench
diag/       hardware bring-up diagnostics (blink, slow-clock FSM viewer)
*.sh, *.tcl build + flash scripts (Gowin gw_sh / programmer_cli on macOS)
```

## Instruction set (16-bit)

`[15:12]` opcode · `[11:9]` rd · `[8:6]` rs · `[5:0]` src2/immediate
(register src2 lives in `[2:0]`).

| opcode | mnemonic | meaning |
|--------|----------|---------|
| 0001 | `ADD rd,rs,rt` | rd = rs + rt |
| 0101 | `ADD rd,rs,#imm` (ADDI) | rd = rs + imm |
| 0010 | `MOV rd,#imm` | rd = imm |
| 0011 | `CMP rs,rt` | set N/Z/P flags |
| 0100 | `LDR` | load (stub) |
| 0110 | `MACL Rs` | push Rs into the 3×3 MAC operand buffer |
| 0111 | `MAC rd` | fire the 3×3 MAC, write result to rd |
| 1000 | `BRn target` | branch if N flag set |
| 1111 | `RET` | halt thread |

### 3×3 MAC unit

`src/mac_array_3x3.v` (a CNN convolution MAC: 9 unsigned pixels × 9 signed
weights → adder tree → ReLU + quantize `>>8`) is wired in as a core-level
functional unit. Because 18 operands don't fit the 2-operand datapath, an
18-byte buffer is filled with `MACL` (9 pixels, then 9 weights), then `MAC rd`
writes the result. See `software/conv_kernel.asm` for a worked example
(`9·30·20 → 21`). Synthesizes to 5 DSP blocks; verified on hardware.

## Quick start

```sh
make sim            # build + run the simulation (self-checks 5*3=15)
make build          # synthesize + place&route  -> impl/pnr/tiny_gpu.fs
make flash          # load into SRAM (volatile)
make flash-persist  # write to SPI flash (survives power cycle)
```

When it runs you should see **LED5 (done) + LED3..0 = `1111` (=15)** lit, with
LED4 dark.

### Serial I/O — send operands, get the product back

`top.sv` speaks **bidirectional UART** over the onboard USB-serial bridge
(**115200 8N1**, FPGA TX = PIN 69, RX = PIN 70):

- **Send** two decimal numbers + Enter, e.g. `7 6`. They patch the kernel's
  operands (`R4 = A`, `R2 = B`); the GPU re-runs and computes `A * B` by
  repeated addition.
- **Receive** the result back as ASCII decimal + CRLF, e.g. `042\r\n`.

```sh
screen /dev/cu.usbserial-XXXX 115200   # the UART interface (not the JTAG one)
# type:  7 6 <Enter>   ->   042
```

> **macOS baud gotcha (cost me a long debug session).** `stty` and plain Python
> `termios` do **not** apply the baud rate to FTDI `cu.usbserial-*` ports — the
> port silently stays at **9600**, and reading 115200 traffic at 9600 produces
> deterministic *garbage* that looks exactly like a broken design but isn't. Use
> `screen` (which sets it correctly), `pyserial`, or the `IOSSIOSPEED` ioctl
> (`fcntl.ioctl(fd, 0x80045402, struct.pack('I', 115200))`). Verify with
> `stty -f <port>` → it should read `speed 115200`, not `9600`.

Of the two FTDI interfaces the board exposes, the **UART is `bInterfaceNumber 1`**
(JTAG is interface 0). Also: `programmer_cli` SRAM loads are sometimes *partial*
over the FT2232 — a run finishing in ~1.7 s (vs the normal ~6.6 s with a
`Status Code` line) did **not** program; reflash and check.

Operands are **6-bit (0–63)** (they land in 6-bit MOV immediates) and the result
is 8-bit, so keep the product ≤ 255. The latest result also shows on the LEDs
(`LED5` = done, `LED3..0` = low nibble). Implemented by `uart_rx.sv` + a decimal
parser and re-run controller in `top.sv`; operands are injected by patching the
ROM in `src/program_memory.sv` (addr 1 → `R2`, addr 3 → `R4`).

## Notes / gotchas (learned the hard way on hardware)

- **`$readmemh` uses an absolute path** in `src/program_memory.sv`. Gowin
  synthesis runs from `impl/gwsynthesis/`, so a *relative* path silently fails
  to load the ROM and the whole design constant-folds away. **If you clone this
  elsewhere, update that path to your checkout location.**
- **No button reset.** The S1 button (PIN 88) did not read high when unpressed
  on this board, which pinned the GPU in reset (dark LEDs). `top.sv` uses
  power-on reset only.
- **GPU clock differs by build.** The **ASCII operand-injection** build (verified
  on hardware) clocks the GPU at **~13 kHz** via a divider — it only needs to run
  the kernel once per input and this stays clear of a thin hold margin. The newer
  **host-driven DMA** build drops the divider and runs the GPU at the full
  **27 MHz** (places & routes with 0 hold violations, Fmax ≈ 97.6 MHz).
- macOS Gowin CLI: `build_fpga.sh` / `flash.sh` point `dyld` at the libraries
  and bundled Tcl framework inside `GowinIDE.app` so `gw_sh` runs headless.

## Toolchain

Icarus Verilog (sim) · Gowin EDA `gw_sh` + `programmer_cli` (synth/P&R/flash) ·
optionally `openFPGALoader` for flashing.
