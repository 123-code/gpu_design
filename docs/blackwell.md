# Blackwell features, in miniature

A B200 is two reticle-sized dies, ~148 SMs, and 192 GB of HBM3e. None of that
scale fits on a Tang Nano 20K. What does fit is the *shape* of each mechanism:
how work is handed out, where operands live, how a tensor core is fed, how
memory traffic overlaps compute. This page lists the Blackwell-style features
the design implements, one section per feature, with the instructions that
drive each one and the testbench that proves it.

| Feature | Blackwell / CUDA counterpart | Test |
|---|---|---|
| [Grid scheduling](#grid-scheduling) | CTA scheduler, `gridDim` | `make sim-grid` |
| [Shared memory + barrier](#shared-memory--barrier) | `__shared__`, `__syncthreads()` | `make sim-smem` |
| [Tensor core + TMEM](#tensor-core--tmem) | 5th-gen tensor core, `tcgen05.mma` / `.ld`, Tensor Memory | `make sim-mma` |
| [FP8 / FP4 / MX block scaling](#fp8--fp4--mx-block-scaling) | `kind::f8f6f4`, `kind::mxf4` (2nd-gen Transformer Engine) | `make sim-mma-all` |
| [TMA bulk copy](#tma-bulk-copy) | Tensor Memory Accelerator, `cp.async.bulk` | `make sim-tma` |
| [Global memory: SDRAM + L1](#global-memory-sdram--l1) | HBM3e + memory controllers, per-SM L1 | `make sim-sdram`, `make sim-global` |
| [Clusters: DSMEM, CBAR, MMA2](#clusters-dsmem-cbar-mma2) | thread-block clusters, distributed shared memory, `cta_group::2` | `make sim-cluster` |
| [Overlapped and pipelined issue](#overlapped-issue) | the SM's instruction pipeline | `make sim-cpi` |
| [On-chip host CPU](#on-chip-host-cpu) | Grace + NVLink-C2C (GB200's CPU sharing memory with the GPU) | `make sim-host` |
| [Board-to-board link](#board-to-board-link) | NVLink / NVL72 (GPUs storing into each other's memory) | `make sim-link` |
| [Linear on the tensor core](#linear-on-the-tensor-core) | cuBLAS/CUTLASS lowering a GEMM onto tensor cores | `make fuzz-tc`, `make sim-mlc MLC_FLAGS=--tc` |

Everything here is checked in simulation (`make regress`). A board subset
places and routes for the GW2AR-18 (see [Board fit](#board-fit)); none of it
has run on hardware yet.

---

## Grid scheduling

**Before:** the dispatcher was one-shot. Block 0 went to core 0, block 1 to
core 1, and that was the launch. The number of blocks was the number of cores.

**Now:** a launch is a grid of `gridDim` blocks, and the dispatcher
(`src/dispatcher.sv`) is a block queue. Whenever a core finishes a block, the
dispatcher pulses that core's reset for one cycle (fresh registers, PCs, LSU
base pointers, warp and divergence state; memory is untouched) and starts it
on the next block. A core that drew a short block simply takes more of them.
This is what an SM's CTA scheduler does, at a scale of two SMs.

- **gridDim comes from the frame header.** The program is at most 256 words,
  so the header's `instr_size` field only needs bits 8:0. Bits 15:9 carry
  gridDim (1..127). `0` means the legacy launch, two blocks, one per core, so
  every existing host script and kernel is unchanged.
  `send_kernel.py --grid N` sets it.
- **`GDIM Rd`** reads gridDim into a register (J++: `gdim`), next to the
  existing `TID`, `BID`, `BDIM`.
- **Output stays in block order.** The UART belongs to the core running the
  lowest unfinished block. A core running a later block stalls on its first
  emit until every earlier block has finished. Blocks can *finish* out of
  order (a block that emits nothing can retire early); a small window
  (`WINDOW = 8` blocks past the oldest unfinished one) records them until the
  blocks before them are done. Issue is in order, so the oldest unfinished
  block is always running and this cannot deadlock.

`make sim-grid` launches 9 blocks of `software/grid_kernel.asm`. Low blocks
are deliberately the slow ones, so one core sits on block 0 while the other
works through later blocks, some of which finish first. The test checks every
block's result, that the reply is in blockIdx order, that each block was
issued exactly once, and that both cores got work (4 and 5 blocks).

---

## Shared memory + barrier

Each core now has a 1 KB scratchpad (`src/shared_memory.sv`) next to its
data memory: 256 words of 32 bits. It is 32 bits wide because the tensor
core (next section) pulls whole operand rows out of it; threads see it as
16-bit halfwords, the register width.

| Instruction | Encoding | Meaning |
|---|---|---|
| `LDS Rd, [Rs]` | `LDR` with imm bit 5 | Rd = shared halfword at byte address Rs |
| `STS Rt, [Rs]` | `STR` with rd field = 1 | shared halfword at byte address Rs = Rt |
| `BAR` | `0xF002` (`RET` with bit 1) | wait until every live warp of the block is here |

No opcode was spent: all 16 are taken, so each new instruction lives in a
field its host instruction leaves unused (`LDR` never used its low 6 bits,
`STR` never used rd, `RET` only used bit 0 for `SYNC`).

Both address spaces go through the same per-core read and write arbiters,
which now carry an address-space bit per request. Main memory still returns a
zero-extended byte; shared memory returns the halfword, and stores use byte
enables so a halfword write leaves the other half of the word alone.

`BAR` parks the warp in a new `WARP_BARRIER` state. When no warp is ready
or waiting on memory and at least one is parked, the scheduler releases them
all. A warp that has already exited does not hold the barrier up.

`make sim-smem` runs a kernel where each of the 8 threads writes a 16-bit
value to shared memory, barriers, and reads its neighbour's slot, which for
threads 3 and 7 belongs to the other warp. All 16 lanes (2 cores x 8) must
read the right value. The same kernel without the `BAR` is the negative
control and must get lanes wrong. It does (2 of 16): the scheduler favours
warp 0, which reads warp 1's slots before warp 1 has written them.

---

## Tensor core + TMEM

The old MAC units (`vector_mac`, `fc_mac`) are a dot-product engine driven
by thread 0, with the accumulator in a register. A Blackwell tensor core
works differently, and `src/tensor_core.sv` copies the three parts that
matter:

1. **Operands come from shared memory, by address.** `MMA Ra, Rb, ...`
   passes the *shared-memory addresses* of A and B in two registers, the
   way a `tcgen05.mma` passes smem descriptors. The unit fetches the tiles
   itself, borrowing the shared-memory read port from the thread LSUs (the
   read arbiter holds off new requests, the unit takes the port once no LSU
   shared read is in flight).
2. **The accumulator lives in Tensor Memory, not in registers.** TMEM is a
   per-core 16 x 128-bit array: 16 columns of 4 rows x int32, i.e. four 4x4
   D tiles. `TLD` copies a column out to the threads, lane i getting row i,
   the way `tcgen05.ld` gives each thread its own TMEM lane.
3. **MMA is asynchronous.** The issuing warp keeps running. Only another
   tensor-core instruction waits for the unit: if it is busy, the warp parks
   (other warps run) and re-executes the instruction when the unit is idle.

One MMA is `D (+)= A x B` on a 4x4 tile with K = 4: A is 4 x K row-major
(row i = one 32-bit word), B is K x 4 stored K-major (column j = one word),
the layout `tcgen05` uses for smem operands.

| Instruction | Encoding | Meaning |
|---|---|---|
| `MMA Ra, Rb, #t, #acc` | `MACL`, rd field 1 | TMEM tile t (0..3) = (acc ? D : 0) + A[Ra] x B[Rb] |
| `TCFG Rs` | `MACL`, rd field 2 | kind = Rs[2:0], `TLDQ` shift = Rs[7:3] |
| `TLD Rd, #c, #h` | `MAC`, rs field 1 | Rd = low (h=0) / high (h=1) half of this lane's row of TMEM column c |
| `TLDQ Rd, #c` | `MAC`, rs field 2 | Rd = clamp(row >>> shift, 0, 255): requantize + ReLU on the way out |

Timing: 8 pipelined shared-memory reads stage A and B, then 5 cycles per
output column (four 4-wide dot products and one 128-bit TMEM write). About
30 cycles for 64 MACs, on 4 multipliers.

`make sim-mma` uses `software/gen_mma_test.py` to build a kernel and random
operands, and `software/tc_ref.py` (the bit-exact model) to compute the
expected bytes. The kernel copies the operands into shared memory, runs
three MMAs (overwrite, accumulate onto the same tile while the unit is still
busy with the first, overwrite a second tile), and reads both tiles back
with `TLD` and tile 0 with `TLDQ`. All 144 result bytes must match on both
cores. The test was checked against two planted bugs (a wrong expected byte,
`accumulate` forced off); both fail it.

---

## FP8 / FP4 / MX block scaling

Blackwell's headline addition is low-precision tensor math: FP8, FP6, FP4,
and *microscaling* (MX) formats where a block of values shares one
power-of-two scale. `TCFG` selects the kind for subsequent MMAs:

| kind | Format | K per MMA | Operand word holds |
|---|---|---|---|
| 0 `s8` | int8 x int8 -> int32 | 4 | 4 bytes |
| 1 `e4m3` | FP8, 1-4-3, bias 7 | 4 | 4 bytes |
| 2 `e2m1` | FP4, 1-2-1, bias 1 | 8 | 8 nibbles, low first |
| 3 `mxf4` | e2m1 + E8M0 block scales | 8 | 8 nibbles; 4 scale bytes follow the tile |

FP4 gets twice the K for the same operand bytes, as on Blackwell: its
multiplier is a handful of LUTs. For `mxf4`, row i of A and column j of B
each carry an E8M0 scale (2^(s-127)); the four scale bytes sit right after
the 16-byte tile, and the unit fetches them as a fifth word. The block is one
MMA's K = 8 (OCP MX uses 32; NVFP4 uses 16 with an E4M3 scale).

**How the math works, and its one rounding.** Every e4m3 code is
`M * 2^(E-9)` with a 4-bit M, and every e2m1 code is `M * 2^(E-1)` with a
2-bit M. So the product of two codes is an exact integer number of 2^-18
(e4m3) or 2^-2 (e2m1) units, and a K-long dot product can be summed exactly
in a wide integer: no alignment loss, no order dependence. Only then is it
moved into D, which for the float kinds is fixed point with 8 fractional bits
(Q.8). For e2m1 that is an exact left shift. For e4m3, and for MX scales
below 2^-6, it is an arithmetic right shift, i.e. floor. The MX shift is
clamped to [-24, 24]. D wraps mod 2^32. That single, documented rounding is
why `software/tc_ref.py` can match the hardware bit for bit. There are no
NaN or infinity codes (e2m1 has none; e4m3's NaN code reads as 480).

This is a deliberate simplification of real tensor cores, which accumulate in
FP32. Fixed-point accumulation is exact within a dot product, cheap in LUTs,
and deterministic. Its limit is range: D is a 32-bit Q.8.

`make sim-mma-all` runs the tensor-core test for every kind: random operand
codes (every e4m3 exponent, every e2m1 code, MX scales spread so the shift
clamp is hit from both sides), checked against the model byte for byte on
both cores. Seeds 1-3 pass for all four kinds.

---

## TMA bulk copy

Feeding a tensor core one `LDR`/`STS` at a time wastes the threads: the
copy loop in the tensor-core test spends more instructions moving operands
than doing math. Hopper and Blackwell hand that job to the Tensor Memory
Accelerator, an engine that moves whole tiles into shared memory on its own
while the threads keep issuing.

`src/copy_engine.sv` is that engine at this scale:

| Instruction | Encoding | Meaning |
|---|---|---|
| `TMA Rs, Rd, #n` | `ADDB` with instruction[10] | copy n words (1..8, 4..32 bytes) from data memory [Rs] to shared memory [Rd], in the background |
| `TMAWAIT` | `0xF004` (`RET` with bit 2) | park until every copy this core issued has landed |

The engine streams one byte per cycle. It borrows the core's data-memory
read port (the LSU read arbiter holds off new requests and the engine takes
the port once no LSU read is in flight) and the shared-memory write port
(the LSU write arbiter grants nothing while the engine is active). One copy
is in flight at a time; a `TMA` issued while one runs, or a `TMAWAIT`, parks
the warp the same way a tensor-core instruction on a busy unit does.

`make sim-tma` reruns the tensor-core test for every kind, with the copy loop
replaced by `TMA`. The kernel is double-buffered: the next pair of tiles
streams in while the first MMA runs. The test requires both the exact result
and a non-zero overlap between copy-engine and tensor-core busy cycles.

| s8 kernel (both cores, from launch to done) | cycles |
|---|---|
| operands staged by a thread copy loop (`make sim-mma`) | 3374 |
| operands staged by TMA (`make sim-tma`) | 1408 |

The tensor core was busy 93 cycles; 25 of them overlapped with a copy.
(Measured when TMA went in. After the issue-loop change below, the same
kernels take 2621 and 1095 cycles, and 27 cycles overlap.)

---

## Global memory: SDRAM + L1

Until now, "memory" meant each core's private 8 KB BRAM, with the DMA
broadcasting the same payload into both copies. Nothing was shared, and
nothing was big. A GPU's defining memory is the opposite: one large, slow,
off-core memory that every SM reads and writes through its own cache.

The Tang Nano 20K's GW2AR-18 has 64 Mbit (2M x 32) of SDR SDRAM inside the
package, and the design never used it. Now it is global memory:

```
 core 0 ─ L1 ─┐                 ┌─ copy engine 0 (TMAG)
              ├─ core 0 port ───┤
              │                 └─ L1 0 (LDG/STG)
 core 1 port ─┼─ mem_arb (round robin) ── sdram_ctrl ── SDRAM (2M x 32)
 host DMA ────┘
```

- **`src/sdram_ctrl.sv`**: closed-page controller. Power-up sequence
  (200 us wait, PRECHARGE ALL, two AUTO REFRESH, LOAD MODE: burst 4, CL 2),
  refresh every 750 cycles, and two operations, both with auto-precharge: a
  4-word line read and a byte-masked word write. The SDRAM is clocked from
  the inverted system clock, so commands are sampled mid-cycle.
- **`src/mem_arb.sv`**: round-robin arbiter, one memory operation at a time.
  Used twice: in each core (L1 vs. copy engine) and at the top (core 0,
  core 1, host DMA).
- **`src/l1_cache.sv`**: per-core 256-byte L1, 16 direct-mapped 16-byte
  lines (one SDRAM burst). Loads that hit return in 2 cycles; a miss fills
  the line with one burst. Stores are write-through, no-write-allocate, and
  *posted*: a one-entry write buffer releases the thread immediately, and a
  later load waits for it to drain, so a core always sees its own stores.
  Like a GPU L1 it is not coherent with the other core's; the per-block
  core reset invalidates it, so each block starts cold.
- **`TMAG`** is `TMA` from global memory, the source a real TMA reads. It
  fetches 16-byte lines straight into shared memory, bypassing the L1.
- **The host can load global memory.** Header `data_size` bit 15 sends the
  payload to SDRAM instead of the data memories
  (`send_kernel.py --global`).

| Instruction | Encoding | Meaning |
|---|---|---|
| `LDG Rd, [Rs]` | `LDR` with imm bit 4 | Rd = global halfword at byte address Rs (through the L1) |
| `STG Rt, [Rs]` | `STR` with rd field = 2 | global halfword at byte address Rs = Rt (posted, write-through) |
| `TMAG Rs, Rd, #n` | `ADDB`, rd field `011` | TMA from global memory [Rs] (16-byte aligned) to shared [Rd] |

**Testing.** `test/sdram_model.sv` is a behavioural model of the SDRAM that
also *checks the protocol*: commands before LOAD MODE, READ/WRITE to a
closed bank, ACTIVE to an open bank, tRCD/tRP/tRC, and missed refresh
deadlines all count as violations. It earned its place immediately: the
first controller draft set A8 instead of A10 for auto-precharge, and the
data still came back right; only the model's "ACTIVE to an open bank"
check (588 of them) exposed it.

- `make sim-sdram`: the controller alone. 300 random byte-masked writes,
  every touched line read back, more than 30 refreshes interleaved, zero
  violations.
- `make sim-global`: the whole path. The host puts operands in SDRAM; a
  grid of 4 blocks does LDG twice per line (one miss, then L1 hits), STG,
  then TMAG's the tiles in and runs two MMAs, and every lane STGs its row
  of D. All four blocks write into the one shared SDRAM, and 1 KB of it is
  checked byte for byte against `software/gen_global_test.py`. Both L1s
  must report hits, and the model must report zero violations. A planted
  bug in the L1 hit path fails the test.

**A block is not done until its work has landed.** A posted store can
still sit in the L1 write buffer after the block's last warp retires, and an
MMA or TMA can still be running. A core now reports done only when its L1 is
idle, its copy engine is idle and its tensor core is idle. Without that, the
dispatcher's reset for the next block could wipe the pending store.
`make sim-drain` (8 short blocks, each ending on an `STG`, with refresh
nearly back to back so stores queue) loses 3 of 32 stores without the fix
and none with it.

On the board, the SDRAM port names follow the Tang Nano 20K's
embedded-SDRAM examples. The SDRAM path has not been run on hardware.

---

## Clusters: DSMEM, CBAR, MMA2

Hopper added thread-block clusters: groups of blocks guaranteed to run at
the same time on neighbouring SMs, able to read and write each other's
shared memory (distributed shared memory) and to barrier together.
Blackwell's tensor core builds on that with `cta_group::2`: two SMs execute
one MMA, each holding half of the B operand. This design has exactly two
cores, so a cluster here is a pair.

- **Cluster launch.** Header `data_size` bit 14 (`send_kernel.py
  --cluster`). The dispatcher then issues blocks in pairs: 2k to core 0
  and 2k+1 to core 1, together, only when both cores are free. A block's
  rank in its pair is `CRANK Rd` (= blockIdx & 1). gridDim should be even.
- **Distributed shared memory.** `LDS`/`STS` with address bit 10 set go
  to the *other* core's shared memory, over a link between the cores. A
  peer's load borrows our shared read port the way the tensor core does; a
  peer's store goes through our write arbiter ahead of our own lanes. A
  DSMEM load waits on the peer's port and leaves ours free. Those two rules
  are what keep two cores that load and store into each other at the same
  time from deadlocking.
- **`CBAR`** (`0xF008`) is a `BAR` that, in a cluster launch, also waits
  for the peer block: each core raises "arrived" once every live warp is
  parked, and both cores release on the same edge once both have arrived.
  Outside a cluster launch it is a plain `BAR`.
- **`MMA2 Ra, Rb, #t, #acc`** (`MACL`, rd field 3) is the 2-SM MMA. B is
  8 columns wide: columns 0..3 live in rank 0's shared memory, 4..7 in
  rank 1's, at the same address. Each core supplies its own A (4 rows) and
  gets a 4 x 8 result in TMEM tiles t and t+1. The tensor core fetches the
  peer's half of B (and its MX scales) over the DSMEM link. So the pair
  computes an 8 x 8 output while each core stages only half of B, which is
  the point of pairing.

`make sim-cluster` (s8 and mxf4) runs one cluster. Rank 1 deliberately
starts late. Each block stores into the peer's shared memory, `CBAR`s,
reads back its own shared memory (the peer's values) and the peer's (by a
DSMEM load), then stages its A and its half of B with `TMA`, `CBAR`s, and
issues `MMA2`. Both cores' results are checked byte for byte. Two planted
bugs fail the test: making `CBAR` not wait for the peer, and having `MMA2`
read the local half of B twice. The first only failed once rank 1 was made
late: with both blocks in lockstep the race never shows.

---

## Overlapped issue

Every instruction used to walk the whole scheduler FSM, one state per
cycle, with nothing overlapped:

```
before:  SELECT_WARP  FETCH  DECODE  REQUEST  EXECUTE  UPDATE      6 cycles
after:                       DECODE  EXECUTE  UPDATE               3 cycles
                                              (+ next FETCH, next warp pick)
```

Two changes, both in `src/scheduler.sv` / `src/registers.sv`:

1. **Fetch overlaps writeback.** In UPDATE, the scheduler already knows
   whether this instruction retires or parks its warp, so it picks the next
   warp then (same policy as before: lowest-index ready warp) and drives the
   instruction memory with that warp's PC. The cycle after UPDATE is the
   next instruction's DECODE. `SELECT_WARP` and `FETCH` only run when no
   warp is ready (waiting on memory, at a barrier, or done).
2. **Operands are read in DECODE.** The register file latches rs/rt
   straight from the instruction word's fields instead of waiting a cycle
   for the registered decoder. Compute instructions then go DECODE ->
   EXECUTE. Loads/stores, tensor-core and copy-engine instructions still
   take REQUEST (the LSU starts there, and the busy-unit check lives there).
   The previous instruction's writeback lands on the edge before DECODE, so
   back-to-back dependent instructions need no forwarding.

| | before | after |
|---|---|---|
| compute loop, 1 warp (`make sim-cpi`) | 6.01 cycles/instr | 3.02 |
| compute loop, 2 warps | 6.00 | 3.01 |
| tensor-core kernel, thread copy loop (`sim-mma`, s8) | 3374 cycles | 2621 |
| tensor-core kernel, TMA staging (`sim-tma`, s8) | 1408 cycles | 1095 |
| compiled CNN, fuzz seed 1 (9 lanes, load-bound) | 202935 cycles | 191307 |

The gain shrinks as memory takes over: the compiled models spend most of
their time in loads that the read arbiter serializes lane by lane (3 cycles
per lane), which this change does not touch.

`make sim-cpi` fails above 3.2 cycles per instruction, so a change that
quietly lengthens the issue loop is caught (the previous design fails it at
6.0).

### Pipelined issue (RUN)

The next step overlaps instructions of the same warp. A new scheduler state,
RUN, executes one instruction (X) while the next one (D, prefetched at X's
PC + 1) is decoded and has its operands read, and the one before X writes
back (W):

```
cycle      t      t+1     t+2     t+3
ADD R1    D       X       W
ADD R4            D       -       X       W     (needs R1: one bubble)
CMP                               D       X  ...
```

What made that possible:

- **Per-stage control.** The decoder latches on a strobe (DECODE, or RUN
  when the next instruction issues) instead of `core_state == DECODE`, and
  the core keeps a registered **W-stage bundle**: destination, write enable,
  writeback mux, the per-lane ALU result (LUI's included), flag write. The
  register file and the N/Z/P flags write from that bundle, so the next
  instruction's decode can overwrite the decoder's outputs safely. The ALU
  takes its opcode from the decoder, not the live ROM output (in RUN that is
  already the next instruction).
- **Hazards.** An instruction that reads the register X is writing waits one
  cycle (a bubble); one cycle later it reads the value off the W-stage
  bypass in the register file. A branch reads flags a CMP right before it
  has not written yet: the PC module forwards the W-stage flags.
- **What leaves RUN.** A taken or divergent branch, an instruction that is
  not ALU / MOV-family / CMP / BRn, or a lower-index warp becoming ready
  (the scheduling policy is unchanged) finishes X through UPDATE, which
  fetches whatever runs next. Memory, tensor-core, copy-engine, RET, SYNC
  and barriers keep the DECODE -> REQUEST/WAIT -> EXECUTE -> UPDATE path.

| compute loop (`make sim-cpi`: ADD, dependent ADD, CMP, taken BRn) | cycles / instruction |
|---|---|
| original FSM | 6.01 |
| overlapped fetch | 3.02 |
| pipelined issue (RUN), 1 warp | 1.77 |
| pipelined issue (RUN), 2 warps | 1.75 |

The loop's 1.77 is 7 cycles for 4 instructions: one bubble for the
dependent ADD and two for the taken branch (UPDATE, then DECODE at the
target). `make sim-cpi` now fails above 2.0.

**What this still is not.** A real SM issues from a different warp almost
every cycle and tracks outstanding writes with a scoreboard, so a branch or
a dependency costs nothing as long as another warp is ready. Here one warp
runs until it stalls, branches are not predicted, and anything slower than
an ALU op leaves the pipeline. That is a narrower machine, and loads, MACs
and tensor-core instructions do not get faster: the compiled models, which
are load-bound, barely move.

---

## On-chip host CPU

A GB200 is not just GPUs: a Grace CPU sits beside them and shares one memory
space with them over NVLink-C2C, so the CPU hands the GPU work and reads its
results without a PCIe hop. Until now this design's host was always the PC
on the other end of a UART.

`src/host_cpu.sv` is a small RV32I core (multi-cycle, no cache, 4 KB of
local RAM for firmware and stack) that can sit on the same die
(`top` parameter `HOST_CPU=1`). It reaches the GPU's global memory through
the same SDRAM arbiter the GPU cores use, as a fourth client. That is the
C2C part: CPU and GPU see one memory, with no copy in between.

| CPU address | What |
|---|---|
| `0x0000_0000` | 4 KB local RAM (firmware, data, stack) |
| `0x1000_0000 + 4i` | GPU instruction word i (write) |
| `0x2000_0000 + a` | global memory byte a (the SDRAM) |
| `0x3000_0000` | write: launch a grid (bits 7:0 gridDim, bit 8 cluster); read: bit 0 = no run in flight |
| `0x3000_0004` | write: send a byte on the UART (blocks until sent) |

The firmware is C (`software/fw/host.c`), built with the system clang for
rv32i (`software/fw/build.py`, linker script `software/fw/link.ld`). The
GPU kernel's machine code is compiled into the firmware as an array.

`make sim-host`: nothing is sent *into* the board. The CPU copies the kernel
into the GPU's instruction memory, writes 8 inputs to SDRAM, launches a
2-block grid, polls until it finishes, reads the 8 results back from SDRAM,
checks them itself, and sends them out over the UART followed by `P` or `F`.
The bench checks the UART bytes and the SDRAM contents independently. With a
planted bug in the GPU kernel, the firmware answers `F` and the bench
reports 9 problems.

Limits: kernels the CPU launches should keep their data in global memory.
The cores' data memories (BRAM) are written by the DMA while it waits for a
UART frame, so GPU stores to them are dropped during a CPU-launched run.

---

## Board-to-board link

An NVL72 rack's 72 GPUs can each store directly into any other's memory over
NVLink. `src/board_link.sv` does that for two boards joined by two wires
(`link_tx` to the other board's `link_rx`):

- A global store (`STG`) whose address has **bit 15** set is remote. Each
  core's global port goes through a `link_router`, which sends such a store
  to the link instead of the SDRAM and acknowledges it once queued, so it
  stays posted. Remote loads are not supported (they read 0); the pattern
  is "push to the peer, then synchronize", as with NVLink stores and a
  barrier.
- The link queues up to 8 stores and sends each as a 5-byte packet
  (`0xA5`, address, data), UART-framed at `LINK_DIV` system clocks per bit.
  That is 13.5 Mbit/s at 54 MHz, about eight orders of magnitude short of
  NVLink 5's 1.8 TB/s per GPU. The receiver turns each packet into a masked
  halfword write to its own SDRAM, at the same address with bit 15 clear, as
  a fifth SDRAM-arbiter client.
- A run is not `done` until the link has sent everything, so a host that
  sees the run finish knows every remote store has left the board.

`make sim-link` simulates two complete boards (each a `top` with its own
SDRAM model) and runs an all-reduce of two 8-element vectors in two phases.
In phase 1 each board stores its vector into the other's memory. In phase 2
each board adds its own vector and the received one. Both boards must end
with v_A + v_B, and each direction must have carried exactly 8 packets.
With remote routing disabled, no packets move and the test fails.

---

## Linear on the tensor core

`graph_compiler --tc` lowers every `Linear` onto the tensor core instead of
the FMAC loop: the step from "the hardware has a tensor core" to "the
compiler uses it".

- **A new MMA kind, `u8` (kind 4): int8 A x uint8 B.** Quantized inference
  multiplies signed weights by post-ReLU activations (0..255), which do not
  fit `s8`. A = 4 neurons x 4 inputs of weights, B column 0 = 4 activations
  (columns 1..3 stay zero), so D column 0 is 4 neurons' accumulators.
- **The planner lays the weights out in tile order**: 16-byte 4x4 tiles,
  zero-padded at the edges, so each A tile is a single `TMA`.
- **`TLDQ` is FOUT.** `clamp(D >>> (8 + shift), 0, 255)` is exactly the
  requantize + ReLU the FMAC path's `FOUT` does, so the compiler's bit-exact
  reference (`eval`) is unchanged and the output must match bit for bit.
  Each lane stores its own neuron.
- **One hardware rule made the loop safe**: a `TMA` waits while the tensor
  core is still reading its operands out of shared memory (`copy_engine`
  `hold`). So "MMA this tile; TMA the next one" needs no double buffering:
  the next tile streams in while the MMA computes, after it has its data.

Per neuron group: `TMA` the weight tile, `TMA` 4 activations, `TMAWAIT`,
`MMA` (accumulate after the first block), and at the end of the group one
`TLDQ` and a store.

| 2-layer MLP 169 -> 32 -> 10, 1 warp x 9 lanes (`make sim-mlc`) | kernel cycles |
|---|---|
| FMAC loops (default) | 829,826 |
| `--tc` | 25,677 |

32x on this model, bit-identical scores. `make fuzz-tc` fuzzes random graphs
with `--tc` against the same three-way check as `make fuzz`; seeds 1-6 and
11-24 pass, and three deep models are rejected at compile time because the
tensor-core code is larger and they no longer fit 256 instruction words.

The fuzzer found one real problem on the way: the last input block of a
Linear reads 4 activations even when fewer are real. Those bytes meet zero
weights, so on hardware their value never matters, but in simulation X * 0
is X and it poisoned the result. The planner now rounds such inputs up to 4
bytes and the prologue zeroes the padding.

Needs a 1-warp launch, as the FMAC path already does.

---

## Board fit

`oss_build/build_board.sh` synthesizes, places and routes one configuration
for the GW2AR-18 and prints nextpnr's utilisation and Fmax. With no
arguments it builds the **board subset**:

- 2 cores x 1 warp x 4 lanes
- tensor core with the int8 kinds only (`TC_KINDS` s8 + u8, the ones
  `graph_compiler --tc` uses), TMA, shared memory, clusters
- no global memory / L1 / SDRAM, no board link, no host CPU

Any other configuration is a list of `chparam` settings for `top`, e.g.
`bash oss_build/build_board.sh big -set THREADS_PER_BLOCK 9 -set BLOCK_DIM 9`.

| Board subset, nextpnr-himbaechel | used / available |
|---|---|
| LUT4 | 16,324 / 20,736 (78%) |
| ALU | 2,704 / 15,552 (17%) |
| DFF | 5,915 / 15,552 (38%) |
| BSRAM | 13 / 46 (28%) |
| DSP (MULT18X18 + MULT9X9) | 8 + 28 |
| sys_clk Fmax | 51.95 MHz against 54 (fails by 4%; see below) |

The worst path in that build was the grid dispatcher's in-order retirement
(block offset, a variable-length drain and the issue window, all
combinational). The dispatcher now retires at most one block per cycle into
a registered window, which removes that path; blocks take thousands of
cycles, so nothing is lost. The rebuild with that change did not get through
placement inside this environment's job time limit, so whether it now makes
54 MHz is unmeasured: run the script again to find out.

For comparison, everything on (2 x 9 lanes, all MMA kinds, L1s, SDRAM,
link) synthesizes to ~71.5k LUT4 + 18.7k ALU, about 4x the chip; with every
new feature off it is the old design. Per-module yosys numbers:

| Module | LUT4 | FF | Notes |
|---|---|---|---|
| `tensor_core` (all 5 kinds, MMA2) | ~7,000 | ~540 | per core; the FP8/FP4/MX datapaths are most of it, hence `TC_KINDS` |
| `l1_cache` | 2,060 | 156 | per core |
| `copy_engine` | 158 | 110 | per core |
| `sdram_ctrl` | 391 | 178 | |
| `board_link` (+ router) | 874 | 249 | |
| `host_cpu` | 3,024 | 385 | 4 KB RAM in 2 BSRAM, register file in 32 RAM16SDP4 |

**Ports.** A feature that is off takes its ports with it (`NO_SDRAM_PORTS`,
`NO_LINK_PORTS`, set by the script), so the default build needs nothing
beyond `gpu.cst`. With global memory on, the embedded SDRAM's `O_sdram_*` /
`IO_sdram_dq` need no constraints: apicula's chip database maps those exact
names to the die's SDRAM, and nextpnr places them itself (checked: a build
with global memory and the link on packs its IO with no constraint errors).
With the link on, `src/gpu_link.cst` puts `link_tx` / `link_rx` on header
pins 29 / 30 (pull-up on `link_rx`); check your board's pinout before wiring.

**Tools.** The script needs no sv2v. With a recent yosys (OSS CAD Suite) it is
one pass. In this environment the system yosys is 0.33, which does not infer
Gowin DSPs and emits block-RAM cells nextpnr rejects, so the numbers above
come from the split flow (`Y71=<yowasp-yosys>`: yosys 0.71 up to LUT mapping,
the system yosys for ABC, YoWASP nextpnr). Memories are mapped without
true-dual-port blocks (`oss_build/gowin/`), which nextpnr cannot place.

None of this has been on a board yet: these are place-and-route results, not
hardware runs.
