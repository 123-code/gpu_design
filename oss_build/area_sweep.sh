#!/usr/bin/env bash
# Fast area-only sweep: sv2v once, then yosys synth_gowin per (WARPS,TPB) config
# via chparam on the top module. Prints LUT/DFF/DSP estimates (no place&route).
# Relative numbers guide config choice; PnR the winner for the true packed count.
set -euo pipefail
: "${OSS_CAD_SUITE:?set OSS_CAD_SUITE}"
source "$OSS_CAD_SUITE/environment"
cd "$(dirname "$0")/.."
mkdir -p oss_build/sweep

echo "==== sv2v ===="
sv2v -DSYNTH src/*.sv -w oss_build/sweep/tiny_gpu.v

# configs: "WARPS TPB BLOCKDIM"  (cores fixed at 2 here)
configs=(
  "2 4 8"     # baseline (8 ALUs, 16 ctx)
  "1 4 4"     # 1 warp, narrow (8 ALUs, 8 ctx)
  "1 8 8"     # 1 warp, 2x width (16 ALUs, 16 ctx)
  "1 12 12"   # 1 warp, 3x width (24 ALUs, 24 ctx)
  "1 16 16"   # 1 warp, 4x width (32 ALUs, 32 ctx)
  "2 6 12"    # 2 warps, modest width (12 ALUs, 24 ctx)
  "2 8 16"    # 2 warps, 2x width (16 ALUs, 32 ctx) -- known ~111%
)

printf "%-18s %8s %8s %8s\n" "WARPS/TPB/BDIM" "LUT4" "DFF" "MULT9X9"
for cfg in "${configs[@]}"; do
  read -r W T B <<<"$cfg"
  log=oss_build/sweep/w${W}_t${T}.log
  yosys -q -p "
    read_verilog oss_build/sweep/tiny_gpu.v;
    chparam -set WARPS_PER_CORE $W -set THREADS_PER_BLOCK $T -set BLOCK_DIM $B top;
    synth_gowin -top top;
    stat
  " > "$log" 2>&1 || { echo "  ($W/$T/$B) FAILED -- see $log"; continue; }
  lut=$(grep -E "GW_LUT|LUT4" "$log" | grep -oE "[0-9]+" | tail -1)
  # yosys stat counts: pull from the "Number of cells" section
  lut=$(awk '/Number of cells/{f=1} f&&/LUT/{s+=$2} END{print s}' "$log")
  dff=$(awk '/Number of cells/{f=1} f&&/DFF/{s+=$2} END{print s}' "$log")
  mul=$(awk '/Number of cells/{f=1} f&&/MULT/{s+=$2} END{print s}' "$log")
  printf "%-18s %8s %8s %8s\n" "$W/$T/$B" "${lut:-?}" "${dff:-?}" "${mul:-0}"
done
echo "(LUT here is yosys pre-pack; nextpnr packs ~+some into MUX. 20736 LUT budget.)"
