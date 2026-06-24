#!/usr/bin/env bash
# Build one (WARPS TPB BLOCK_DIM) config through yosys+nextpnr and report the
# real packed LUT utilisation and STA Fmax. Does NOT pack a bitstream (STA only).
#   bash oss_build/build_cfg.sh <WARPS> <TPB> <BLOCKDIM>
set -uo pipefail
: "${OSS_CAD_SUITE:?set OSS_CAD_SUITE}"
source "$OSS_CAD_SUITE/environment"
cd "$(dirname "$0")/.."
W=$1; T=$2; B=$3
tag="w${W}_t${T}"
mkdir -p oss_build/cfg
sv2v -DSYNTH src/*.sv -w oss_build/cfg/${tag}.v
yosys -q -p "
  read_verilog oss_build/cfg/${tag}.v;
  chparam -set WARPS_PER_CORE $W -set THREADS_PER_BLOCK $T -set BLOCK_DIM $B top;
  synth_gowin -top top -json oss_build/cfg/${tag}.json
" 2>oss_build/cfg/${tag}.synth.log
echo "=== nextpnr ($W warps / TPB $T / BLOCK_DIM $B) ==="
nextpnr-himbaechel --json oss_build/cfg/${tag}.json \
   --write oss_build/cfg/${tag}_pnr.json \
   --device "GW2AR-LV18QN88C8/I7" --vopt family=GW2A-18C --vopt cst=src/gpu.cst \
   --freq "${FREQ:-81}" 2>oss_build/cfg/${tag}.pnr.log
echo "CFG=$W/$T/$B"
grep -E "LUT4:|DFF:|BSRAM:|MULT9X9:|Max frequency for clock 'sys_clk'" oss_build/cfg/${tag}.pnr.log
# Optional 4th arg: pack a flashable bitstream to oss_build/<name>.fs
if [ "${4:-}" != "" ]; then
    gowin_pack -d GW2A-18C -o "oss_build/$4.fs" oss_build/cfg/${tag}_pnr.json
    echo "PACKED oss_build/$4.fs"
fi
echo "DONE_CFG_$W_$T_$B"
