# tiny-gpu on the Tang Nano 20K — a GPU running a CNN

A minimal, dual core SIMT GPU in SystemVerilog,synthesized to a Sipeed Tang Nano 20K FPGA. 



The GPU has two independent compute cores, each core has its own multi warp scheduler, stack based flow control for branch divergence and reconvergence, global thread indexing, and a dedicated MAC coproccessor for heavy matrix math( imitating the role of tensor cores in an NVIDIA GPU)


## Architecture
**Central Dispatcher:** At the top level a central dispatcher manages two completely independent compute cores: core0 and core1. Each core is physically instantiated with:

- its own 8kb data memory on BSRAM
- its own 256-word instruction ROM



**SIMT core** Each SIMT core is governed by a centralized hardware scheduler and a decoder, the default configuration manages 2 warps per core, and implements 4 physical ALU lanes. Warps are interleaved dynamically, every indepentent thread osseses its own:
-Registers: A 16 slot register file
-Program Counter: Instruction pointers
-Load store unit: allow threads to read from one memory region and store to another.

![tiny-gpu single core](docs/core_detail.png)


**Zero-Penalty Context Switching:** Because a full instruction takes 6 clock cycles (Fetch -> Decode -> Request -> Wait -> Execute -> Update), the ALUs are mostly idle. The 2 warps time multiplex the 4 ALUs. If warp 0 issues a memory read, the scheduler parks it in a WAIT state, and connects the ALUs to warp 1. This design hides memory latency without stalling the pipeline

**Hardware Branch Divergence:** SIMT requires threads to execute in lockstep. To handle situations where threads within a warp evaluate an if/else statement differently (divergence), we use a thread mask. This mask controls the write-enable pin for the registers and memory; if a thread's mask bit is 0, it is "asleep" and its state cannot change.

Because the entire warp shares a single Program Counter, divergent paths must be executed one after the other. The scheduler manages this using a Hardware Reconvergence Stack:

When a branch splits, the scheduler pushes the mask of the sleeping threads and the address of the untaken path onto the stack, and runs the active path.
At the end of the path, a SYNC instruction tells the hardware to pop the stack.
The hardware jumps to the untaken path and swaps the mask—putting the first group of threads to sleep and waking up the second group.
Once both sides of the branch finish (the stack is empty), the hardware restores the full mask so the entire warp can reconverge and run the following code in lockstep.

**32 Bit Math Coprocessors:**
he GPU operates on a strict 8-bit datapath to save FPGA logic, which isn't enough for the massive accumulations in CNNs. To solve this, Thread 0 of the active warp drives two 32-bit coprocessors:

Vector MAC: An 8-lane multiplier tree. Threads buffer 8 pixel/weight pairs, then fire a single MAC instruction to compute 8 parallel products and accumulate them in one cycle.
FC Accumulator: A persistent 32-bit accumulator for the fully-connected layers.
To get these massive 32-bit results back into the 8-bit register file, the hardware uses a byte-select multiplexer. Software issues MAC Rd, #n to safely slice out byte n (0 through 3) of the coprocessor's output.

**Extreme Parametrization:**Because the RTL relies entirely on parameters rather than hardcoded widths, the architecture is highly malleable. Using the build-oss-max target in the Makefile, you can drop the latency-hiding (WARPS_PER_CORE = 1) and widen the ALUs to 12 physical lanes per core, instantly compiling a 24-lane GPU that hits 127 MHz.


**The whole chip.** Two of those cores sit under a dispatcher, fed by the host UART → DMA →
memory chain, with the result emitted back over UART. Every block name matches a module in
`src/*.sv`.

![tiny-gpu architecture](docs/gpu_overview.png)

## Instruction Set Architecture (16-bit)

Every instruction is a 16-bit word, decoded strictly as:
`[15:12]` opcode · `[11:9]` rd · `[8:6]` rs · `[5:0]` imm (register rt in `[2:0]`).

| Opcode | Mnemonic | Meaning / Operation |
|--------|----------|---------|
| `0000` | `FRST`/`FMAC`<br>`FARG`/`FBEST` | **FC-MAC Coprocessor** (sub-fn in `[5:4]`): reset / `acc+=rs*rt` / finalize digit (add int32 bias, latch logit score) / read logit LSB. |
| `0001` | `ADD rd,rs,rt` | rd = rs + rt |
| `0010` | `MOV rd,#imm` | rd = imm (6-bit immediate) |
| `0010` | `TID`/`BID`<br>`BDIM rd` | `MOV` with `rs`≠0: rd = threadIdx (R15) / blockIdx (R13) / blockDim (R14) |
| `0011` | `CMP rs,rt` | set N/Z/P flags (Negative, Zero, Positive) |
| `0100` | `LDR rd,[rs]` | rd = mem[rbase + rs] (Load from Memory) |
| `0101` | `ADDI rd,rs,#imm` | rd = rs + imm |
| `0110` | `MACL rs` | Push an operand pair into the 8-lane Vector MAC buffer. |
| `0111` | `MAC rd, #n` | Fire the Vector MAC → slice byte `#n` (0-3) of the 32-bit sum into rd. |
| `1000` | `BRn target` | Branch if N (8-bit target, pushes mask to stack on divergence). |
| `1001` | `ADDB #imm` / `WBASE #imm` | Advance read base / write base (`[11]` selects). |
| `1010` | `MUL rd,rs,rt` | rd = rs · rt |
| `1011` | `STR rt,[rs]` | mem[wbase + rs] = rt (Store to Memory. Note: rs==63 → UART TX) |
| `1100`/`1101`/`1110` | `SHR`/`SHL`/`SUB` | Bit shift right / Bit shift left / Subtract |
| `1111` | `RET` | Halt thread |
| `1111` | `SYNC` | Pop the reconvergence stack, swap active thread mask (`[0]`=1). |
| *(pseudo)* | `MAX rd,ra,rb` | Assembler-expanded macro (`CMP` + `BRn` + `ADDI`). |

> **Note on Registers:** Only **R0–R7** are instruction-addressable (3-bit fields). R13–R15 are SIMT identity registers, readable via `TID`/`BID`/`BDIM` (which copy them into an R0–R7 register).

### Programming the tiny-gpu: Key Hardware Quirks

Writing assembly for this GPU requires understanding a few custom hardware features designed to maximize CNN performance on a minimal FPGA footprint.

#### 1. SIMT Branch Divergence (`BRn` and `SYNC`)
Because all threads in a warp share a single Program Counter, they must execute in lockstep. If a `CMP` evaluates differently for different threads, a `BRn` instruction will cause **divergence**. 
* The hardware automatically pushes the sleeping threads' mask and the untaken path's address onto a **Reconvergence Stack**, and runs the active path.
* You **must** place a `SYNC` instruction at the end of the branch. This pops the stack, swapping the thread mask to run the opposite path, and eventually reconverging the warp.

#### 2. The 8-bit to 32-bit Boundary (`MAC`, `MACL`)
The GPU uses a strict 8-bit datapath to save logic, but CNN accumulations require 32-bit math. 
* Use `MACL` to stream operand pairs into the 8-lane Vector MAC.
* When you fire `MAC Rd, #n`, the coprocessor generates a massive 32-bit sum. Because `Rd` is only 8 bits, use the byte-selector `#n` (0 through 3) to extract specific 8-bit slices of the result one by one.

#### 3. Identity and Divergent Loads (`TID`)
To process parallel data, threads need to know who they are. Fetching `TID` (Thread ID) allows the 8 lanes to diverge their memory access. For example: `TID R1` followed by `LDR R2,[R1]` loads `mem[threadIdx]` for each individual lane.




Two ways to run it:

- **Live (board attached).** With the Tang Nano plugged in, the page auto-enables
  *Live* mode: draw → the image is streamed over UART, the FPGA classifies it, and the
  **digit + cycle-accurate timing come straight from silicon**.
- **Gallery (no hardware).** With no board (or when opened as a static page — it's
  hostable on GitHub Pages), the page falls back to *Gallery* mode and replays captured
  runs from `demo/recordings/`. Capture your own:

  ```sh
  make record                       # canonical 0–9 spread, real on-chip timing (needs the board)
  python3 demo/record.py --offline  # stages only, no board (reference digit, no timing)
  ```

> **What's real vs. reference:** the **digit and timing are read back from the actual
> FPGA**. The conv/pool/FC stage *images* are rendered from `mnist_ref.py`, the bit-exact
> software model of the same RTL (verified equal in simulation: conv 676/676, pool
> 169/169) — so they show exactly what the chip computed, without a firmware change to
> dump the intermediate BRAMs.


## How it works

```
   PC ──UART(115200)──▶ DMA ──▶ image @ addr 0      (784 bytes)
                                     │
                 ┌───────────────────┴─────────────────────────────┐
                 │  GPU runs software/mnist_full.asm  (one kernel)  │
                 │   Conv 3×3  (MAC coprocessor, baked weights)     │
                 │     → ReLU + >>8 quantize  → conv map (BRAM)      │
                 │   MaxPool 2×2  (MAX pseudo-op)  → pooled (BRAM)   │
                 │   Scatter pooled features into the FC buffer     │
                 │   FC 169→10  (FC-MAC: 32-bit acc + int32 bias)   │
                 │     → argmax  → predicted digit                  │
                 └───────────────────┬─────────────────────────────┘
                                     ▼
   PC ◀──UART──  predicted digit (1 byte)
```


## Synthesis & utilization (Tang Nano 20K · GW2AR-18C)

From `impl/pnr/tiny_gpu.rpt.html` (full Conv→Pool→FC pipeline build):

| Resource              | Used                                | Available | Util. |
|-----------------------|-------------------------------------|-----------|-------|
| Logic (LUT+ALU)       | 1501 (1052 LUT4, 449 ALU)           | 20736     | 8 %   |
| Registers             | 878 (877 FF + 1 I/O)                | 15750     | 6 %   |
| CLS (slices)          | 1180                                | 10368     | 12 %  |
| Block SRAM            | 4 SDPB + 1 pROM                     | 46        | 11 %  |
| DSP                   | 4× MULT9X9 + 5× MULTADDALU18X18     | —         | 25 %  |
| I/O ports             | 9                                   | 66        | 14 %  |
| PLL                   | 0                                   | 2         | 0 %   |

**Timing:** 

## Flashing — the reliable recipe (read this, it'll save you an hour)

The Tang Nano shows up as **two** USB-serial devices. Both matter:

```sh
ls /dev/cu.usbserial-*       # macOS — two ports appear
```

- the **lower-numbered** port = FTDI interface 0 = **JTAG** (used to *flash*)
- the **higher-numbered** port = FTDI interface 1 = **UART** (used to *talk* to the design)

### Option A — `openFPGALoader` (recommended)

```sh
brew install openfpgaloader                                   # one-time
openFPGALoader -b tangnano20k impl/pnr/tiny_gpu.fs            # SRAM: fast, volatile
openFPGALoader -b tangnano20k -f impl/pnr/tiny_gpu.fs         # SPI flash: survives power-cycle
```

### Option B — bundled Gowin `programmer_cli` via `flash.sh` (SRAM only)

```sh
FS="$(pwd)/impl/pnr/tiny_gpu.fs" ./flash.sh
```

- **Use an absolute `FS` path.** `programmer_cli` rejects a relative one with
  `Error: Not found any data File`. (`flash.sh` defaults to the in-bundle Gowin project's
  `.fs`; override `FS` to flash *this* repo's build.)
- **A good flash looks like this** — check for all three:
  ```
  Target Device: GW2AR-18C(0x0000081B)
  Status Code is: 0x00006020
  Finished.                       Cost 5–7 second(s)
  ```

### When it fights you (it will) — how to recover

| symptom | meaning | fix |
|---|---|---|
| `Error: Error found!` or finishes in **~1.7 s** | partial / failed program | just run the flash **once** more |
| `Cable failed to open via the channel` | the FT2232 bridge has wedged (usually from rapid retries) | **unplug the board, replug, wait ~3 s, try one clean flash** |
| board stops responding after a USB drop | SRAM is volatile + the USB-powered board browned out and lost its config | reflash |
| ports vanish from `/dev/cu.*` | FTDI de-enumerated | replug |

**The golden rule: don't hammer it.** Rapid back-to-back flash attempts are what wedge the
cable. Do **one** attempt; if it errors, wait a couple seconds and try **once** more; if the
cable won't open, **replug and do a single clean flash**. SRAM loads are volatile — use the
SPI-flash option (or `make flash-persist`) if you want it to survive a power cycle.

### Then run it

Stream an image over the **UART** port (the higher-numbered one). On macOS, set the baud
with `screen`/`pyserial`/`IOSSIOSPEED` — plain `stty` silently leaves it at 9600 (see
gotchas):

```sh
cd software && python3 send_mnist.py mnist_data/image0.hex     # -> predicted digit
```

## Repo layout

```
src/        gpu, core, scheduler, dispatcher, decoder, registers, alu, pc, lsu,
            lsu_arbiter, mac_array_3x3 (conv MAC), fc_mac (FC + argmax),
            main_memory, dma_controller, data_pipeline, uart_rx/tx, top
software/   Rust assembler (src/main.rs); mnist_full.asm (the CNN kernel);
            mnist_ref.py (reference model + image/weight dumps); mnist_data/ (weights,
            biases, images, baked-buffer inits); send_mnist.py (host streamer)
test/       tb*.sv — staged self-checking testbenches (conv, pool, full pipeline, FC, ...)
*.sh,*.tcl  headless Gowin build/flash on macOS
```

## Notes / gotchas (learned the hard way)

- **DMA re-arm uses a rising edge of `gpu_done`,** not its level — `gpu_done` stays high
  after a run, so level-triggering bounced the DMA back into "loading" on the next run and
  blocked that run's memory writes (it returned a stale result). See `dma_controller.sv`.
- **`$readmemh` paths are absolute** (`program_memory.sv`, `main_memory.sv`, `fc_mac.sv`):
  Gowin synthesis runs from `impl/gwsynthesis/`, so relative paths silently fail. Update
  them if you move the checkout.
- **macOS FTDI baud:** `stty`/plain `termios` do *not* set the baud on `cu.usbserial-*`
  ports (they stay at 9600 → 115200 traffic reads as garbage). Use `screen`, `pyserial`,
  or the `IOSSIOSPEED` ioctl (`fcntl.ioctl(fd, 0x80045402, struct.pack('I', 115200))`).
  The **UART is FTDI `bInterfaceNumber 1`** (JTAG is interface 0).
- **`programmer_cli` flashes are intermittently partial** over the FT2232 — a run ending in
  ~1.7 s (vs ~6 s with a `Status Code` line) did *not* program; reflash. Rapid open/close
  can wedge the cable (replug to recover).
- **Simulation:** zero `main_memory` in the testbench — real BSRAM powers up to 0 but sim
  is `X`, and one `X` feature poisons the FC argmax.
- **No button reset** (S1/PIN 88 read low here); `top.sv` uses power-on reset only.

## Toolchain

Icarus Verilog (sim) · Gowin EDA `gw_sh` + `programmer_cli` (synth/P&R/flash) ·
Python 3 (reference model + host streamer) · optionally `openFPGALoader`.
