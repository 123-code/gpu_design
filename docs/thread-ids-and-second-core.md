# Roadmap: usable thread IDs + a second compute core

Two ways to make tiny-gpu "more real" as a GPU. Part 1 is a concrete implementation
plan. Part 2 is a **feasibility check only** (no code) — does a second core still fit and
flash on this Tang Nano 20K (GW2AR-18C)? Yes, with caveats; reasoning below.

---

## Part 1 — Make thread IDs actually usable (real SIMT data parallelism)

> **✅ IMPLEMENTED.** `TID` / `BID` / `BDIM` exist as a `MOV`-variant (`rs` field selects the
> identity register). Verified in `test/tb_tid.sv`: the 4 lanes read distinct `threadIdx`
> (`R1 = 0,1,2,3`) and a divergent `LDR R2,[R1]` loads `mem[threadIdx]` per lane
> (`software/divergent_load.asm`). MNIST regression (`tb_mnist_full`, digit 7) still passes.
> The write path note below still holds — only thread 0's stores reach memory, so the
> demonstration uses divergent *reads* through the existing `lsu_arbiter`.

### Where we are today (before this change)
The hardware already *has* per-thread identity registers (`src/registers.sv`):

```
registers[13] = %blockIdx   (set from block_id)
registers[14] = %blockDim   (= THREADS_PER_BLOCK)
registers[15] = %threadIdx  (= THREAD_ID, unique per lane: 0,1,2,3)
```

Each of the 4 threads in a block is parameterized with its own `THREAD_ID`, so the silicon
*knows* which lane it is. **But no instruction can read those registers.** The decoder
slices register fields as 3-bit (`decoded_rs_address <= {1'b0, instruction[8:6]}`, same for
rd/rt), so only **R0–R7** are addressable; R13–R15 are unreachable. Net effect: the 4
threads execute the *same* instructions on the *same* addresses and produce *identical*
results — there is no real per-thread divergence. It's SIMT plumbing without SIMT payoff.

### Goal
Let each thread compute a **distinct** address from its `threadIdx`, so the 4 lanes process
4 different data elements per instruction (e.g. 4 conv output columns at once). The 4-way
`lsu_arbiter` already serializes 4 distinct memory reads — it's ready for divergent
addresses; it just never gets any.

### Approach (minimal, mirrors how `WBASE` was added)
Adding a brand-new opcode is hard (the 16 opcodes are full). Instead, **overload `MOV`'s
unused `rs` field** to read an identity register into an addressable one:

- `MOV rd, #imm` today: opcode `0010`, `rd=[11:9]`, `rs=[8:6]` unused (always `000`),
  `imm=[5:0]`.
- Define `TID rd` (and `BID`/`BDIM`) as `MOV` with `rs ≠ 0` selecting an identity reg:
  `rs=1 → threadIdx (R15)`, `rs=2 → blockIdx (R13)`, `rs=3 → blockDim (R14)`.
- `registers.sv`: when this MOV-variant is decoded, mux `registers[15/13/14]` into the
  writeback instead of the immediate. (One new `decoded_*` strobe, like `decoded_wbase_add`.)

So `TID R5` puts this lane's index (0..3) into R5, an addressable register. From there the
kernel does ordinary arithmetic: `offset = base + threadIdx`, and each lane loads/stores its
own element.

### Files to change
- `src/decoder.sv` — decode the MOV-variant (`rs` field) → new `decoded_rd_src_sel`.
- `src/registers.sv` — writeback mux: select `registers[13/14/15]` for that variant.
- `software/src/main.rs` — assembler mnemonics `TID/BID/BDIM rd`.
- A demo kernel (e.g. `software/tid_demo.asm`): 4 threads each write `threadIdx*K` to
  `mem[base + threadIdx]`.

### Verify
- Sim: run one block, read back `mem[0..3]` — expect 4 *distinct* per-lane values
  (today they'd be identical). Add `test/tb_tid.sv`.
- Then refactor a pipeline stage (e.g. pooling: 4 lanes do 4 output columns/iteration) and
  confirm the output map still matches `mnist_ref.py` while doing ~4× fewer iterations on
  that stage.

### Honest caveat
The conv-MAC and FC-MAC coprocessors are **single, thread-0-driven** accumulators. Thread
IDs give real parallelism for **per-thread ALU / independent work** (and for divergent
addressing), but the shared MACs stay serial. Full 4× on the conv/FC math would also need
per-lane accumulators (4 MAC units) — bigger, see DSP budget in Part 2.

---

## Part 2 — A second compute core: feasibility check (no code written)

**Question:** can we add a second functional compute core and still fit + flash this FPGA?

### What's already there
`src/gpu.sv` already instantiates **two** cores (`compute_core_0`, `compute_core_1`) and
`src/dispatcher.sv` already round-robins blocks across both (`core_0_*` / `core_1_*`). But
`compute_core_1`'s inputs are tied to constants (`.current_instruction(16'd0)`,
`.mem_rdata(8'd0)`, …), so **synthesis prunes it** — the post-synth netlist contains only
**one** `mac_array_3x3`. So today's numbers are effectively a *single* functional core.

### Resource math (from the current post-P&R report)
One functional core + shared memory/UART/DMA currently uses:

| Resource | 1 core (now) | est. 2 cores | device | fits? |
|----------|--------------|--------------|--------|-------|
| Logic (LUT+ALU) | 1501 (8%) | ~3000 (~15%) | 20736 | ✅ |
| Registers | 878 (6%) | ~1700 (~11%) | 15750 | ✅ |
| CLS (slices) | 1180 (12%) | ~2300 (~23%) | 10368 | ✅ |
| DSP | 9 (25%) | ~18 (~50%) | ~36 | ✅ |
| BSRAM | 4 SDPB +1 pROM (11%) | ~11% (shared) | 46 | ✅ |

The data memory (8 KB) and instruction ROM are **shared**, so a second core barely moves
BSRAM. The binding constraint is **DSP** (each core carries its own 3×3 conv MAC ≈ 5 DSP +
FC-MAC ≈ 1), going 25% → ~50%. Everything else stays under ~25%.

### Verdict: **YES — it fits and would still flash.**

**Why yes:**
- Comfortable headroom on every axis; DSP (~50%) is the tightest and still half-empty.
- Timing has slack today (Fmax ~77 MHz vs 27 MHz target); a second core adds area, not a
  longer critical path, so 27 MHz closure is very likely to hold.
- The scaffolding (dual instantiation + dispatcher) already exists.

**Why you might still say "not yet" (these are integration costs, not capacity limits):**
1. **Shared memory needs a cross-core arbiter.** `main_memory` has one read port and one
   write port. The `lsu_arbiter` only serializes the 4 threads *within* one core. Two cores
   need a top-level arbiter, and the single write port is now shared by the DMA **and** two
   cores — real contention to design correctly.
2. **One UART emit.** Only one core can own the `emit`/TX path; the other must route results
   through memory.
3. **Work must be partitioned.** Nothing uses core 1 today. To get speedup, the MNIST kernel
   + dispatcher must split the work (e.g. core 0 does conv rows 0–12, core 1 rows 13–25),
   which is a kernel/dispatch redesign — not a fitting problem.
4. **DSP doubles only if MACs are per-core.** Sharing one MAC between cores saves DSP but
   serializes the math (less benefit).

### Bottom line
Capacity-wise it's a clear **yes** — two functional cores fit on the GW2AR-18C with room to
spare and should close timing at 27 MHz. The work is in **memory arbitration + work
partitioning**, not in whether the bitstream fits the chip.
