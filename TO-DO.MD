# Where the ML compiler work stands

Branch `ml-compiler`. Last validated on hardware Sep 15 2026 (Tang Nano 20K).

## What works now

A quantized graph compiles to a data image + kernel and runs on the FPGA:

    software/export_model.py          model            -> models/*.json
    software/src/bin/graph_compiler.rs  JSON           -> build/*.asm, *.data.hex, *.expect.hex
    software/src/main.rs              asm              -> hex
    software/send_kernel.py           program + data   -> FPGA over UART

    make mlc        # compile the model
    make sim-mlp2   # end-to-end sim, checked byte-for-byte against the reference
    make run-mlp2   # same thing on the board

A 169->32->10 int8 MLP returns all 10 scores plus the argmax, bit-exact against
the compiler's own reference evaluator, on both cores.

Two FCU ops were added, both reusing existing encoding slots via an
`instruction[3]` modifier (no opcode spent):

    FACC Rd,#n   byte n of the raw signed 32-bit accumulator
    FOUT Rd,#t   clamp(acc >>> (8+t), 0, 255), then clear acc
                 -- requantize + saturate + ReLU in one instruction

`main_memory.sv` no longer bakes weights at synthesis. The bitstream is
model-independent: every weight arrives over UART as data.

## Needs the board (can't be done away from the FPGA)

Anything under `make run-*`, `build-oss*`, `flash*`. The 1-warp bitstream is
`oss_build/tiny_gpu_ml.fs`, built with:

    OSS_CAD_SUITE=~/oss-cad-suite FREQ=54 bash oss_build/build_cfg.sh 1 9 9 tiny_gpu_ml

1 warp is mandatory for anything touching fc_mac -- the accumulator is thread-0
driven, so 2 warps double-drive every FMAC. Everything else (compiler, iverilog
sims) runs anywhere: `make sim-mlp2` needs only iverilog and cargo.

## Next, in the order I'd do them

1. **Per-lane accumulators in fc_mac.** The big one. Today all 9 lanes
   redundantly recompute the SAME neuron, and every LDR becomes 9 serialized
   arbiter reads -- roughly 9x slower than necessary. Giving each lane its own
   accumulator makes lanes compute DIFFERENT neurons. The per-lane write path
   this needs already works (see `make sim-mlp`).

2. **Biases.** Layers are currently bias-free (`y = W2*relu(W1x)`). fc_mac's
   `bias.hex` ROM is the last thing about a model still baked into hardware.
   The fix is a bias tensor in memory plus a small op to add it before FOUT.

3. **Streaming MAC.** One tap currently costs ~8 instructions. An instruction
   that walks the operand stream in hardware for n taps would cut that to
   ~2 cycles/tap. This is the single largest perf lever in the whole design.

4. **Command stream / layer overlays.** Not needed yet -- both layers fit in one
   256-word kernel. Needed the moment a model doesn't. The DMA already re-arms
   on `gpu_done`, and BRAM survives `gpu_reset`, so layer-at-a-time loading with
   activations persisting in memory needs only a destination address in the DMA
   header (~5 lines in `dma_controller.sv` + `send_kernel.py`).

5. **Trained weights.** `export_model.py` emits seeded-random int8 today (no
   torch on the build machine). Swapping in trained weights is a change to that
   one file -- which is the property that makes the rest of it a compiler.

## Gotchas that cost time

- `expect` is a reserved SystemVerilog keyword; don't name a testbench reg that.
- Host runs need `--pad 1`: the DMA silently drops the final payload byte.
- `MOV` immediates are 6-bit (0..63). Anything larger needs `LDI` (3 words).
- `SHR`/`SHL` take the shift amount in a REGISTER, not an immediate.
- Stores commit late; don't re-read an address you just wrote a few cycles ago.
