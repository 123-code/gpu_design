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

## Board fit

The board build is `oss_build/build_cfg.sh` (yosys + nextpnr-himbaechel),
which this environment does not have. The features above have not been
synthesized, placed, or timed for the GW2AR-18. Treat them as simulated RTL.
