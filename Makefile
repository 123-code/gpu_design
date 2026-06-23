# tiny-gpu on the Tang Nano 20K
# Common tasks. The FPGA build/flash steps shell out to the helper scripts,
# which set up the macOS library paths the Gowin CLI tools need.

IVERILOG ?= iverilog
VVP      ?= vvp

.PHONY: sim sim-loadrun sim-divergence sim-divmerge sim-warps build flash flash-persist asm demo record clean

sim:            ## Build + run the simulation (self-checks that 5*3 = 15)
	$(IVERILOG) -g2012 -s tb -o gpu_sim test/tb.sv src/*.sv src/*.v
	$(VVP) gpu_sim

sim-loadrun:    ## General load->run->readback: stream a kernel+data over UART, run, check reply
	cd software && cargo run --quiet -- sum_kernel.asm sum_kernel.hex
	$(IVERILOG) -g2012 -s tb -o sim_loadrun test/tb_loadrun.sv src/*.sv
	$(VVP) sim_loadrun

sim-divergence: ## Validate per-lane SIMT branch divergence (lanes take different paths)
	cd software && cargo run --quiet -- divergence_kernel.asm divergence_kernel.hex
	$(IVERILOG) -g2012 -s tb -o sim_divergence test/tb_divergence.sv src/*.sv
	$(VVP) sim_divergence

sim-divmerge:   ## Validate divergence + reconvergence (common code runs on all lanes after merge)
	cd software && cargo run --quiet -- divmerge_kernel.asm divmerge_kernel.hex
	$(IVERILOG) -g2012 -s tb -o sim_divmerge test/tb_divmerge.sv src/*.sv
	$(VVP) sim_divmerge

sim-warps:      ## Prove 2 warps run distinct global thread IDs (BLOCK_DIM=8 -> 8 lanes 0..7)
	cd software && cargo run --quiet -- tid_demo.asm tid_demo.hex
	$(IVERILOG) -g2012 -s tb -o sim_warps test/tb_warps.sv src/*.sv
	$(VVP) sim_warps

demo:           ## Serve the draw-a-digit web demo at http://localhost:8000
	python3 demo/server.py

record:         ## Capture FPGA runs into demo/recordings/ for the Gallery (use --offline for no board)
	python3 demo/record.py

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
