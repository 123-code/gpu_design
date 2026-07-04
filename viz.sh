#!/usr/bin/env bash
# Render one RTL module to an SVG schematic (gates / FFs / wires).
# Usage: ./viz.sh <module>   e.g.  ./viz.sh lsu   ./viz.sh alu   ./viz.sh pc
# Whole-GPU schematics are an unreadable hairball — view leaf modules.
set -e
M=${1:?usage: ./viz.sh <module-name>}
# Read just this module's file. Works for leaf FSMs (lsu, alu, pc, decoder,
# registers, uart_tx). Hierarchical modules (core, top) need every src file
# and yosys trips on core.sv's array-of-instances — view the leaves instead.
yosys -q -p "read_verilog -sv src/$M.sv; prep -top $M; write_json /tmp/$M.json"
netlistsvg /tmp/$M.json -o "$M.svg"
echo "wrote $M.svg  (open it: open $M.svg)"
