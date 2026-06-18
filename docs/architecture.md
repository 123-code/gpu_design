# tiny-gpu architecture

Block diagrams generated from the RTL (`src/`). Three zoom levels: the board-level
system, the GPU, and one compute core with its SIMT thread lanes.

## System level (`top.sv` + `data_pipeline.sv`)

```mermaid
flowchart LR
  host["Host PC"]

  subgraph TOP["top.sv (Tang Nano 20K, 27 MHz)"]
    subgraph PIPE["data_pipeline.sv"]
      rx["uart_rx"]
      dma["dma_controller"]
      wmux{"write-port mux<br/>loading ? DMA : GPU"}
      mem["main_memory<br/>8 KB dual-port BRAM"]
    end
    runctl["run control<br/>(reset / enable arming)"]
    gpu["gpu.sv"]
    etx["emit-&gt;UART FSM"]
    tx["uart_tx"]
    led["led[5:0]"]
  end

  host -- "UART 115200<br/>2x784-byte images" --> rx
  rx -- "rx_byte / rx_valid" --> dma
  dma -- "dma_we/waddr/wdata" --> wmux
  gpu -- "gpu_we/waddr/wdata (STR)" --> wmux
  wmux --> mem
  mem -- "mem_rdata" --> gpu
  gpu -- "mem_raddr" --> mem
  dma -- "gpu_start" --> runctl
  runctl -- "reset / enable" --> gpu
  gpu -- "done" --> dma
  gpu -- "emit_valid/data" --> etx --> tx -- "predicted digit" --> host
  gpu -- "result / done / loading" --> led
```

## GPU level (`gpu.sv`)

```mermaid
flowchart TB
  subgraph GPU["gpu.sv"]
    disp["dispatcher<br/>(one block per core,<br/>done = both cores done)"]
    rom["program_memory<br/>256x16 instruction ROM<br/>(core 0's copy)"]
    rom1["program_memory<br/>(core 1's copy)"]
    core0["core 0 (block 0)"]
    core1["core 1 (block 1)"]
  end

  disp -- "core_0_start / id" --> core0
  disp -- "core_1_start / id" --> core1
  core0 -- "done" --> disp
  core1 -- "done" --> disp
  core0 -- "instruction_address (PC)" --> rom
  rom -- "current_instruction[15:0]" --> core0
  core1 -- "instruction_address (PC)" --> rom1
  rom1 -- "current_instruction[15:0]" --> core1
  core0 -- "mem_raddr / mem_we/waddr/wdata / emit" --> ext["to main_memory copy 0 / UART"]
  core1 -- "mem_raddr / mem_we/waddr/wdata / emit" --> ext1["to main_memory copy 1 / UART<br/>(served after core 0)"]
  core0 -- "result" --> ext
```

Each core owns a private copy of the kernel ROM and of `main_memory` (the
core↔memory read path has no handshake, so the BRAM ports can't be time-shared).
The host streams **two 784-byte images per run**; the DMA writes the first into
core 0's memory copy and the second into core 1's, and the cores classify them
concurrently. The dispatcher is one-shot per run (a core's DONE state is
terminal until the per-run GPU reset), so `TOTAL_BLOCKS` must be ≤ 2 and `done`
is the AND of both cores' sticky done levels.

**Emit protocol** (gpu-level FSM): the single UART serves core 0's bytes first —
core 1's LSU just stalls on the emit handshake until core 0 is terminally done —
and a 24-bit cycle counter (start→done, MSB-first) is hardware-appended after
each core's bytes. Per run the host receives 8 bytes:
`[digit0][cycles0 ×3][digit1][cycles1 ×3]`. Core 1's count includes its wait
for core 0's UART bytes (~9.4k cycles for 4 bytes at 115200).

## Core level (`core.sv`) — SIMT, 4 threads/block

```mermaid
flowchart TB
  instr["current_instruction"] --> dec

  subgraph CORE["core.sv"]
    dec["decoder<br/>16-bit -> control signals"]
    sched["scheduler<br/>FSM: FETCH/DECODE/REQUEST/<br/>WAIT/EXECUTE/UPDATE"]
    arb["lsu_arbiter<br/>4-&gt;1 mem read port"]
    mac["mac_array_3x3<br/>shared conv MAC<br/>(baked weights, DSP)"]
    fc["fc_mac<br/>shared FC MAC<br/>(32-bit acc + bias, argmax)"]

    subgraph LANES["thread lanes x4 (genvar)"]
      regs["registers<br/>R0-R7, R13-R15 SIMT IDs"]
      alu["alu"]
      lsu["lsu<br/>rbase/wbase + offset"]
      pc["pc<br/>NZP branch"]
    end
  end

  dec -- "control bus" --> sched
  dec -- "control bus" --> regs
  dec -- "alu mux / opcode" --> alu
  dec -- "mem r/w, base add" --> lsu
  dec -- "nzp, pc mux" --> pc
  dec -- "fc_clear/mac/arg/read" --> fc
  dec -- "mac_load / fire" --> mac

  sched -- "core_state" --> dec
  sched -- "core_state" --> LANES
  lsu -- "lsu_state" --> sched

  regs -- "rs / rt" --> alu
  regs -- "rs / rt" --> lsu
  regs -- "rs[0]/rt[0]" --> mac
  regs -- "rs[0]/rt[0]" --> fc
  alu -- "alu_out" --> regs
  alu -- "alu_out" --> pc
  lsu -- "lsu_out" --> regs
  pc -- "next_pc" --> pc
  mac -- "result" --> wbmux{"mux: fc_read ?<br/>fc : conv"}
  fc -- "result" --> wbmux
  wbmux -- "mac_result writeback" --> regs

  lsu -- "mem req (valid/addr)" --> arb
  arb -- "ready / rdata" --> lsu
  arb -- "mem_raddr" --> memext["main_memory"]
  memext -- "mem_rdata" --> arb
  lsu -- "thread0: we/waddr/wdata, emit" --> memext
  pc -- "thread0 PC" --> romext["program_memory"]
```

Notes:
- Only **thread 0** drives stores, the conv/FC MACs, and emit (SIMT-uniform model);
  reads from all 4 lanes are serialized by `lsu_arbiter`.
- The two MAC coprocessors are **core-level shared** units, not per-lane — same split
  of labor as tensor cores beside scalar lanes on a real GPU.
- Both cores are fully wired (own ROM copy + own data-memory copy); only core 0
  reaches the UART/LEDs.
