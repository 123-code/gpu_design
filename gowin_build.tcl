# ============================================================================
# Gowin gw_sh build script for tiny-gpu on the Tang Nano 20K.
# Run via ./build_fpga.sh (which sets the macOS library paths gw_sh needs).
# Produces a .fs bitstream under impl/pnr/.
# ============================================================================

# Tang Nano 20K = GW2AR-18 in the QN88 package, speed grade C8/I7
set_device GW2AR-LV18QN88C8/I7

# ---- RTL sources (everything in src/ except this is the synthesis set) ----
add_file src/alu.sv
add_file src/decoder.sv
add_file src/registers.sv
add_file src/pc.sv
add_file src/lsu.sv
add_file src/scheduler.sv
add_file src/mem_controller.sv
add_file src/memory_fifo.sv
add_file src/program_memory.sv
add_file src/core.sv
add_file src/dispatcher.sv
add_file src/gpu.sv
add_file src/top.sv

# ---- Physical + timing constraints ----
add_file src/gpu.cst
add_file src/gpu.sdc

set_option -top_module top
set_option -verilog_std sysv2017
set_option -output_base_name tiny_gpu

run all
