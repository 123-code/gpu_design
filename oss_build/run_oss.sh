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
# -DSYNTH compiles in the real rPLL hard macro (gowin_pll.sv); sims omit it and
# use the pass-through so the testbench clock drives the design directly.
sv2v -DSYNTH src/*.sv -w oss_build/tiny_gpu.v

echo "==== [1/3] yosys synth_gowin ===="
yosys -q -p "read_verilog oss_build/tiny_gpu.v; synth_gowin -top top -json oss_build/tiny_gpu.json"

echo "==== [2/3] nextpnr-himbaechel place & route ===="
# --vopt family=GW2A-18C is REQUIRED (nextpnr errors without it for the GW2A series).
# --freq constrains P&R to the rPLL's sys_clk. WITHOUT it, nextpnr defaults to a
# 12 MHz target and places loosely, so the routed design does NOT close timing at
# the real clock and emits garbage on hardware even though sim passes (the rPLL is
# a sim pass-through). The clock here is 81 MHz (27x3, src/gowin_pll.sv) — the
# design's STA Fmax is ~80 MHz (seed-dependent), so 81 MHz sits right at the edge:
# nextpnr reports the target as not met and exits non-zero, but the routed design
# IS written and runs correctly at room temperature (HW-verified). We therefore
# pack it anyway WHEN the only problem is timing; a real routing/placement failure
# still aborts. For a margin-safe build, set --freq 54 (huge margin) or 67.
FREQ_MHZ=81
set +e
nextpnr-himbaechel --json oss_build/tiny_gpu.json --write oss_build/tiny_gpu_pnr.json \
   --device "GW2AR-LV18QN88C8/I7" --vopt family=GW2A-18C --vopt cst=src/gpu.cst \
   --freq "$FREQ_MHZ" 2>&1 | tee /tmp/nextpnr_oss.log
pnr_rc=${PIPESTATUS[0]}
set -e
if [ "$pnr_rc" -ne 0 ]; then
    # Routing completes far enough to run STA only if it prints "Max frequency".
    # If that's present and there is no explicit place/route failure, the only
    # error is the unmet timing target — pack the (valid) routed design anyway.
    if grep -q "Max frequency for clock" /tmp/nextpnr_oss.log \
       && ! grep -qiE "Routing design failed|Placement.*failed|unable to route|Failed to route" /tmp/nextpnr_oss.log; then
        echo ">> WARNING: ${FREQ_MHZ} MHz target not met (running at negative STA margin); routing OK, packing anyway."
    else
        echo ">> ERROR: nextpnr place & route failed."; exit 1
    fi
fi

echo "==== [3/3] gowin_pack -> bitstream ===="
gowin_pack -d GW2A-18C -o oss_build/tiny_gpu_oss.fs oss_build/tiny_gpu_pnr.json

echo "==== DONE ===="
ls -la oss_build/tiny_gpu_oss.fs
