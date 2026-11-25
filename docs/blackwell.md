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

Everything here is checked in simulation (`make regress`). None of it has been
built for or run on the board yet; see [Board fit](#board-fit).

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

## Board fit

The board build is `oss_build/build_cfg.sh` (yosys + nextpnr-himbaechel),
which this environment does not have. The features above have not been
synthesized, placed, or timed for the GW2AR-18. Treat them as simulated RTL.
