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

## Board fit

The board build is `oss_build/build_cfg.sh` (yosys + nextpnr-himbaechel),
which this environment does not have. The features above have not been
synthesized, placed, or timed for the GW2AR-18. Treat them as simulated RTL.
