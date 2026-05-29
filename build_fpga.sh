#!/usr/bin/env bash
# Build the Tang Nano 20K bitstream for tiny-gpu using the Gowin IDE's
# command-line shell (gw_sh) shipped inside GowinIDE.app.
#
# macOS note: GowinIDE.app isn't a normal CLI install, so we point dyld at the
# Gowin libs and the bundled Tcl.framework before invoking gw_sh.
set -euo pipefail

GW="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA"
LIB="$GW/IDE/lib"
GW_SH="$GW/IDE/bin/gw_sh"

cd "$(dirname "$0")"   # run from the repo root so $readmemh finds software/kernel.hex

DYLD_LIBRARY_PATH="$LIB" DYLD_FRAMEWORK_PATH="$LIB" "$GW_SH" gowin_build.tcl

echo
echo "Bitstream(s) produced:"
find impl -name "*.fs" 2>/dev/null || echo "  (none — check the log above for errors)"
