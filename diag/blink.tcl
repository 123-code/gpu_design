set_device GW2AR-LV18QN88C8/I7
add_file diag/blink.sv
add_file src/gpu.cst
set_option -top_module top
set_option -verilog_std sysv2017
set_option -output_base_name blink
run all
