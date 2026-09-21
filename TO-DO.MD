# Where the ML compiler work stands

Branch `graph-ir` (built on `ml-compiler`). Last validated on hardware Sep 2026,
Tang Nano 20K.

## What works now

A PyTorch model compiles to a data image + kernel and runs on the chip:

    export_torch.py    nn.Module --torch.fx--> quantized SSA graph (models/*.json)
    export_model.py    synthetic models, no torch needed
    graph_compiler.rs  SSA graph -> legalize -> fuse -> plan -> asm + bit-exact reference
    main.rs            asm -> hex
    send_kernel.py     program + data -> FPGA over UART

    make mlc MODEL=mnist_cnn IMAGE=3           # compile
    make sim-mlp2                              # end-to-end sim vs the reference
    make run-mlp2 MODEL=mnist_mlp IMAGE=0..9   # on the board
    make fuzz FUZZ_N=200                       # differential fuzz (see Verification)

Ops lowered today: `Linear`, `Relu`, `Argmax`, `Conv2d(1->C, KxK, stride 1)+Relu`,
`MaxPool2d(kxk, stride k)`, `Flatten`. `Linear->Relu` and `Linear->Argmax` fuse
into one FMAC loop + FOUT. Legalize rejects the rest *by name* rather than
miscompiling: `cin>1`, stride/padding, conv without Relu, Linear without
Flatten, out-of-memory.

Trained models, chip-exact int8 accuracy measured before anything is flashed:

| model      | float  | chip-exact int8 | kernel     | data        |
|------------|--------|-----------------|------------|-------------|
| mnist_mlp  | 93.41% | 93.43%          |            |             |
| mnist_cnn  | 95.15% | 94.91%          | 179/256 w  | 5882/8192 B |

Both are bit-exact on the board against the reference, on both cores.

Two FCU ops carry this, both reusing existing encoding slots via an
`instruction[3]` modifier (no opcode spent):

    FACC Rd,#n   byte n of the raw signed 32-bit accumulator
    FOUT Rd,#t   clamp(acc >>> (8+t), 0, 255), then clear acc
                 -- requantize + saturate + ReLU in one instruction

Nothing about a model is in the bitstream: `main_memory.sv` bakes no weights,
and every weight arrives over UART as data.

## Verification

`make fuzz` generates random graphs and checks three implementations agree
bit-for-bit: the Python graph reference, `graph_compiler`'s Rust reference, and
the RTL (`test/tb_mlc.sv`, the board's 1-warp/9-lane config). It is
mutation-tested — planted FOUT-shift, reference-shift, conv-step and pool-step
bugs are all caught. Run it after touching codegen, lowering, or fc_mac.

## Needs the board attached

`make run-*`, `build-oss*`, `flash*`. The 1-warp bitstream is
`oss_build/tiny_gpu_ml.fs`:

    OSS_CAD_SUITE=~/oss-cad-suite FREQ=54 bash oss_build/build_cfg.sh 1 9 9 tiny_gpu_ml

1 warp is mandatory for anything touching fc_mac — the accumulator is thread-0
driven, so 2 warps double-drive every FMAC. Everything else (compiler, sims,
fuzzer) runs anywhere with iverilog + cargo; torch is only needed to re-run
`export_torch.py`, and `models/` is committed so you don't have to.

## Next, in the order I'd do them

1. **Per-lane accumulators in fc_mac.** The big one. All 9 lanes currently
   recompute the SAME neuron and every LDR becomes 9 serialized arbiter reads —
   roughly 9x slower than necessary. Per-lane accumulators let lanes compute
   DIFFERENT neurons. The per-lane write path already works (`make sim-mlp`).

2. **Command stream / layer overlays.** Now the near-term blocker, not a
   someday: `mnist_cnn` is 179 of 256 kernel words, so the next layer or two
   will not fit. The DMA already re-arms on `gpu_done` and BRAM survives
   `gpu_reset`, so layer-at-a-time loading with activations persisting in memory
   needs only a destination address in the DMA header (~5 lines in
   `dma_controller.sv` + `send_kernel.py`). Each layer then gets all 256 words.

3. **`cin>1` convolution.** Legalize rejects it today, which caps CNNs at one
   input channel — the reason `mnist_cnn` is conv(1->2) and not something real.

4. **Biases.** Still bias-free (`y = W2*relu(W1x)`); `export_torch.py` rejects
   models with bias. fc_mac's `bias.hex` ROM is the last model-shaped thing left
   in hardware. Wants a bias tensor in memory + an op to add it before FOUT.

5. **Streaming MAC.** One tap costs ~8 instructions. An instruction that walks
   the operand stream in hardware for n taps would get to ~2 cycles/tap — the
   single largest perf lever in the design, but it needs 1 and 2 first to be
   worth it.

## Gotchas that cost time

- `expect` is a reserved SystemVerilog keyword; don't name a testbench reg that.
- Host runs need `--pad 1`: the DMA silently drops the final payload byte.
- `MOV` immediates are 6-bit (0..63); larger constants need `LDI` (3 words).
- `SHR`/`SHL` take the shift amount in a REGISTER, not an immediate.
- Stores commit late; don't re-read an address you wrote a few cycles ago.
- Address 63 is the memory-mapped UART. `plan()` steps GPU-written buffers over
  it — a fuzzer finding, not a theoretical one.
