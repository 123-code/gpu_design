#!/usr/bin/env bash
# Synthesize, place and route one board configuration for the Tang Nano 20K
# and print nextpnr's real utilisation and Fmax.
#
#   bash oss_build/build_board.sh                 # the default board subset
#   bash oss_build/build_board.sh <name> <yosys chparam settings for top...>
#   PACK=1 bash oss_build/build_board.sh          # also write oss_build/<name>.fs
#
# No sv2v: the design reads straight into yosys. Memories are mapped with
# oss_build/gowin/brams_nodp.txt (see its README): no true-dual-port blocks,
# which nextpnr-himbaechel cannot place. Features that are switched off take
# their ports with them (NO_SDRAM_PORTS / NO_LINK_PORTS), so gpu.cst covers
# every pin; with LINK_ENABLE on, src/gpu_link.cst is added. The embedded
# SDRAM's O_sdram_* / IO_sdram_dq pins need no constraints: nextpnr places
# them from apicula's system-in-package pin map.
#
# Tools. A recent yosys (OSS CAD Suite) does everything in one pass. Older
# yosys (< 0.40) does not infer Gowin DSPs and emits BRAM cells nextpnr
# rejects; set Y71=<path to yowasp-yosys> to run yosys 0.71 for everything
# before LUT mapping and the system yosys for ABC (the YoWASP ABC crashes in
# some sandboxes). NEXTPNR defaults to nextpnr-himbaechel.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "${OSS_CAD_SUITE:-}" ]; then source "$OSS_CAD_SUITE/environment"; fi
NEXTPNR="${NEXTPNR:-nextpnr-himbaechel}"
FREQ="${FREQ:-54}"

name="${1:-board}"; shift || true
if [ "$name" = "board" ] && [ $# -eq 0 ]; then
    # The default board subset: 2 cores x 1 warp x 4 lanes, tensor core with
    # the int8 kinds (s8, and u8 for graph_compiler --tc), TMA, shared
    # memory, clusters. No global memory / L1 / SDRAM, no link, no host CPU.
    set -- -set WARPS_PER_CORE 1 -set THREADS_PER_BLOCK 4 -set BLOCK_DIM 4 \
           -set TC_KINDS 17 -set GMEM_ENABLE 0 -set LINK_ENABLE 0 -set HOST_CPU 0
fi
params="$*"
defs="-DSYNTH"
cst="src/gpu.cst"
case " $params " in *"GMEM_ENABLE 0"*) defs="$defs -DNO_SDRAM_PORTS";; esac
case " $params " in
    *"LINK_ENABLE 0"*|*"GMEM_ENABLE 0"*) defs="$defs -DNO_LINK_PORTS";;
    *) mkdir -p oss_build/board; cat src/gpu.cst src/gpu_link.cst > oss_build/board/$name.cst
       cst="oss_build/board/$name.cst";;
esac

out="oss_build/board"
mkdir -p "$out"
srcs=$(ls src/*.sv | grep -v fpu.sv | tr '\n' ' ')
front="read_verilog -defer -sv $defs $srcs
  chparam $params top"
mem="memory_libmap -lib +/gowin/lutrams.txt -lib oss_build/gowin/brams_nodp.txt
  techmap -map +/gowin/lutrams_map.v -map +/gowin/brams_map.v"

echo "=== synth: $name ($params)"
if [ -z "${Y71:-}" ]; then
    yosys -q -l "$out/$name.synth.log" -p "
      $front
      synth_gowin -top top -run begin:map_ram
      $mem
      synth_gowin -top top -run map_ffram: -json $out/$name.json
      tee -q -o $out/$name.stat stat"
else
    "$Y71" -q -l "$out/$name.y71.log" -p "
      $front
      synth_gowin -family gw2a -top top -run begin:map_ram
      $mem
      synth_gowin -family gw2a -top top -run map_ffram:map_luts
      blackbox =A:whitebox
      write_json $out/$name.pre.json"
    yosys -q -l "$out/$name.synth.log" -p "
      read_json $out/$name.pre.json
      hierarchy -top top
      abc -lut 4:8
      clean
      techmap -map oss_build/gowin/cells_map.v
      opt_lut_ins -tech gowin
      hilomap -singleton -hicell VCC V -locell GND G
      clean
      autoname
      write_json $out/$name.json
      tee -q -o $out/$name.stat stat"
fi

echo "=== nextpnr: $name"
set +e
$NEXTPNR --json "$out/$name.json" --write "$out/${name}_pnr.json" \
    --device "GW2AR-LV18QN88C8/I7" --vopt family=GW2A-18C --vopt cst="$cst" \
    --freq "$FREQ" > "$out/$name.pnr.log" 2>&1
rc=$?
set -e
grep -E "ERROR|LUT4:|DFF:|ALU:|BSRAM:|MULT18X18:|MULT9X9:|RAM16SDP4:|Max frequency for clock" \
    "$out/$name.pnr.log" | tail -12 || true
if [ $rc -ne 0 ]; then echo "nextpnr failed (rc=$rc), see $out/$name.pnr.log"; exit $rc; fi
if [ -n "${PACK:-}" ]; then
    gowin_pack -d GW2A-18C -o "oss_build/$name.fs" "$out/${name}_pnr.json"
    echo "PACKED oss_build/$name.fs"
fi
