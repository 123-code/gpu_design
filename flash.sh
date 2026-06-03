#!/usr/bin/env bash
# Flash the tiny-gpu bitstream to a Tang Nano 20K.
#
#   ./flash.sh         -> load into SRAM (fast, volatile: gone on power cycle)
#   ./flash.sh flash   -> write to external SPI flash (persistent across reboots)
#
# Preferred tool: openFPGALoader  (install once: `brew install openfpgaloader`)
# Fallback:       Gowin programmer_cli (shipped inside GowinIDE.app)
set -euo pipefail
cd "$(dirname "$0")"

# Bitstream to flash. The canonical artifact is produced by the Gowin IDE
# project in the app bundle; override with `FS=/path/to.fs ./flash.sh` if needed.
GOWIN_GPU="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/bin/gpu"
FS="${FS:-$GOWIN_GPU/impl/pnr/gpu_uart.fs}"
[ -f "$FS" ] || FS="impl/pnr/tiny_gpu.fs"   # fall back to a local headless build
[ -f "$FS" ] || { echo "No bitstream found (looked in the Gowin project and impl/pnr/). Build first."; exit 1; }
echo ">> Flashing: $FS"

MODE="${1:-sram}"

if command -v openFPGALoader >/dev/null 2>&1; then
    if [ "$MODE" = "flash" ]; then
        echo ">> Writing to external SPI flash (persistent)…"
        openFPGALoader -b tangnano20k -f "$FS"
    else
        echo ">> Loading into SRAM (volatile)…"
        openFPGALoader -b tangnano20k "$FS"
    fi
else
    echo "openFPGALoader not found. Recommended: brew install openfpgaloader"
    echo "Falling back to Gowin programmer_cli (SRAM only here)…"
    GW="/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA"
    LIB="$GW/IDE/lib"
    # operation_index 2 = SRAM Program. For persistent external-flash programming,
    # use the Gowin Programmer GUI (Access Mode: External Flash Mode).
    DYLD_LIBRARY_PATH="$LIB" DYLD_FRAMEWORK_PATH="$LIB" \
        "$GW/Programmer/bin/programmer_cli" \
        --device GW2AR-18C --operation_index 2 --fsFile "$FS"
fi
