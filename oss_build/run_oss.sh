#!/usr/bin/env bash
# ============================================================================
# Open-source bitstream build for tiny-gpu on the Tang Nano 20K (GW2AR-18C).
#
# Why this exists: Gowin's proprietary GowinSynthesis (./build_fpga.sh) SIGSEGVs
# inferring main_memory's block RAM on the current multi-warp design, and that
# toolchain build has no syn_ramstyle escape hatch. The open-source flow uses a
# different synthesizer with no such bug:
#     sv2v -> yosys/synth_gowin -> nextpnr-himbaechel -> gowin_pack (apicula)
#
# Requires the YosysHQ oss-cad-suite bundle (provides nextpnr-himbaechel +
# gowin_pack + apicula chipdb). Point OSS_CAD_SUITE at its root:
#     export OSS_CAD_SUITE=/path/to/oss-cad-suite
#     bash oss_build/run_oss.sh        (or: make build-oss)
# Then flash with:  make flash-oss     (openFPGALoader -> SRAM, volatile)
# ============================================================================
set -euo pipefail
: "${OSS_CAD_SUITE:?set OSS_CAD_SUITE to your oss-cad-suite install root}"
source "$OSS_CAD_SUITE/environment"

cd "$(dirname "$0")/.."
mkdir -p oss_build

echo "==== [0/3] sv2v (SystemVerilog -> Verilog) ===="
sv2v src/*.sv -w oss_build/tiny_gpu.v

echo "==== [1/3] yosys synth_gowin ===="
yosys -q -p "read_verilog oss_build/tiny_gpu.v; synth_gowin -top top -json oss_build/tiny_gpu.json"

echo "==== [2/3] nextpnr-himbaechel place & route ===="
# --vopt family=GW2A-18C is REQUIRED (nextpnr errors without it for the GW2A series).
nextpnr-himbaechel --json oss_build/tiny_gpu.json --write oss_build/tiny_gpu_pnr.json \
   --device "GW2AR-LV18QN88C8/I7" --vopt family=GW2A-18C --vopt cst=src/gpu.cst

echo "==== [3/3] gowin_pack -> bitstream ===="
gowin_pack -d GW2A-18C -o oss_build/tiny_gpu_oss.fs oss_build/tiny_gpu_pnr.json

echo "==== DONE ===="
ls -la oss_build/tiny_gpu_oss.fs
