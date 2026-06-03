# tiny-gpu on the Tang Nano 20K
# Common tasks. The FPGA build/flash steps shell out to the helper scripts,
# which set up the macOS library paths the Gowin CLI tools need.

IVERILOG ?= iverilog
VVP      ?= vvp

.PHONY: sim build flash flash-persist asm clean

sim:            ## Build + run the simulation (self-checks that 5*3 = 15)
	$(IVERILOG) -g2012 -s tb -o gpu_sim test/tb.sv src/*.sv src/*.v
	$(VVP) gpu_sim

asm:            ## Re-assemble software/test_kernel.asm -> software/kernel.hex
	cd software && cargo run --quiet

build:          ## Synthesize + place & route -> impl/pnr/tiny_gpu.fs
	./build_fpga.sh

flash:          ## Load the bitstream into SRAM (volatile, gone on power cycle)
	./flash.sh

flash-persist:  ## Write the bitstream to external SPI flash (survives reboot)
	./flash.sh flash

clean:
	rm -f gpu_sim *.vcd
	rm -rf impl
