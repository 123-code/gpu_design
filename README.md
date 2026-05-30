# tiny-gpu on the Tang Nano 20K

A small SIMT GPU core in SystemVerilog, with a Rust assembler, simulated with
Icarus Verilog and synthesized to a **Sipeed Tang Nano 20K** (Gowin GW2AR-18C).
The demo kernel computes `5 * 3 = 15` by repeated addition and shows the result
on the onboard LEDs.

## Status

- ✅ Simulation passes (`R3 = 15`, core reaches `DONE`).
- ✅ Synthesizes and runs on real hardware — the result lights up the LEDs.

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
| 1000 | `BRn target` | branch if N flag set |
| 1111 | `RET` | halt thread |

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
- **The GPU is clocked at ~13 kHz** (divided from 27 MHz) in `top.sv`. It only
  needs to run the kernel once; this stays clear of a thin (~0.4 ns) hold margin
  seen at full speed.
- macOS Gowin CLI: `build_fpga.sh` / `flash.sh` point `dyld` at the libraries
  and bundled Tcl framework inside `GowinIDE.app` so `gw_sh` runs headless.

## Toolchain

Icarus Verilog (sim) · Gowin EDA `gw_sh` + `programmer_cli` (synth/P&R/flash) ·
optionally `openFPGALoader` for flashing.
