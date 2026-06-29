# tiny-gpu on the Tang Nano 20K
# Common tasks. The FPGA build/flash steps shell out to the helper scripts,
# which set up the macOS library paths the Gowin CLI tools need.

IVERILOG ?= iverilog
VVP      ?= vvp

.PHONY: sim sim-loadrun sim-divergence sim-divmerge sim-warps sim-mac32 sim-mlp build build-oss build-oss-max flash flash-oss flash-oss-max flash-persist bench asm demo record clean run-jpp

# J++: compile a .jpp source -> asm -> hex, then stream it to the FPGA and read
# the reply. Usage: make run-jpp JPP=software/program.jpp READ=8
JPP  ?= software/program.jpp
READ ?= 8
run-jpp:        ## Compile + run a J++ program on the FPGA. Usage: make run-jpp JPP=software/foo.jpp
	cd software && cargo run --quiet --bin jpp -- $(notdir $(JPP)) program.asm
	cd software && cargo run --quiet -- program.asm program.hex
	cd software && python3 send_kernel.py program.hex --read $(READ)

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

sim-mac32:      ## Prove the full 32-bit MAC result reads back via MAC Rd,#n (4 bytes -> 4800)
	cd software && cargo run --quiet -- mac_read32.asm mac_read32.hex
	$(IVERILOG) -g2012 -s tb -o sim_mac32 test/tb_mac32.sv src/*.sv
	$(VVP) sim_mac32

sim-mlp:        ## Parallel FC layer: 9 lanes each compute+write their own neuron (per-lane write path)
	cd software && cargo run --quiet -- mlp_parallel.asm mlp_parallel.hex
	$(IVERILOG) -g2012 -s tb -o sim_mlp test/tb_mlp.sv src/*.sv
	$(VVP) sim_mlp

bench:          ## Measure real ALU ops/s on the board (needs the max18 bitstream flashed)
	cd software && cargo run --quiet -- bench_ops.asm bench_ops.hex
	python3 software/bench_host.py

demo:           ## Serve the draw-a-digit web demo at http://localhost:8000
	python3 demo/server.py

record:         ## Capture FPGA runs into demo/recordings/ for the Gallery (use --offline for no board)
	python3 demo/record.py

asm:            ## Re-assemble software/test_kernel.asm -> software/kernel.hex
	cd software && cargo run --quiet

build:          ## Synthesize + place & route -> impl/pnr/tiny_gpu.fs
	./build_fpga.sh

build-oss:      ## Open-source bitstream (yosys+nextpnr+apicula). GowinSynthesis crashes on this design; set OSS_CAD_SUITE first
	bash oss_build/run_oss.sh

flash-oss:      ## Flash the open-source-built bitstream into SRAM
	openFPGALoader -b tangnano20k oss_build/tiny_gpu_oss.fs

build-oss-max:  ## MAX AI-capable bitstream: 2 cores x 1 warp x 9 lanes = 18 ALU lanes, per-lane writes (78% LUT, 140 MHz). Set OSS_CAD_SUITE first
	bash oss_build/build_cfg.sh 1 9 9 tiny_gpu_max18

flash-oss-max:  ## Flash the 18-lane MAX bitstream into SRAM
	openFPGALoader -b tangnano20k oss_build/tiny_gpu_max18.fs

flash:          ## Load the bitstream into SRAM (volatile, gone on power cycle)
	./flash.sh

flash-persist:  ## Write the bitstream to external SPI flash (survives reboot)
	./flash.sh flash

clean:
	rm -f gpu_sim *.vcd
	rm -rf impl
