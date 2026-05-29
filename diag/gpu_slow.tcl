set_device GW2AR-LV18QN88C8/I7

# all RTL except src/top.sv (gpu_slow.sv provides the top module instead)
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
add_file diag/gpu_slow.sv

add_file src/gpu.cst

set_option -top_module top
set_option -verilog_std sysv2017
set_option -output_base_name gpu_slow
run all
