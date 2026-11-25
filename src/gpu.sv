`default_nettype none
`timescale 1ns/1ns

module gpu #(
    // Launch size (threads per block). Default 8 -> 2 warps per core, with
    // distinct global thread IDs (warp0 = 0..3, warp1 = 4..7). Set to 4 to launch
    // a single warp (no redundant second warp) for 4-thread kernels.
    parameter BLOCK_DIM = 8,
    // Warp width = physical ALU lanes per core (the per-cycle SIMD width). This is
    // the main throughput lever: peak ALU ops ~= NUM_CORES*THREADS_PER_BLOCK*f/7.
    parameter THREADS_PER_BLOCK = 4,
    // Warps per core. >1 hides memory latency but DUPLICATES each thread's register
    // file / LSU / PC (ALUs are shared), so it costs ~2x LUT for the same compute.
    // Set to 1 to spend that LUT on wider SIMD (more ALUs) instead.
    parameter WARPS_PER_CORE = 2,
    // feature switches (see core.sv)
    parameter TC_ENABLE   = 1,
    parameter TC_KINDS    = 5'b11111,
    parameter TMA_ENABLE  = 1,
    parameter GMEM_ENABLE = 1
) (
    input wire clk,//clock input
    input wire reset,//reset signal, clears internal states to 0
    input wire enable,//when on, gpu issues thread blocks
    input wire [7:0] grid_dim,//blocks in this launch (0 = legacy: 2 blocks, one per core)
    input wire cluster,//cluster launch: blocks 2k, 2k+1 co-scheduled as a pair
    output wire [7:0] result,//result from core 0
    output wire done,//when high, gpu has finished
    output wire [2:0] debug_core_state,//for debuging , shows the internal state of each core
    output wire [15:0] debug_instruction,//explores current active instruction, allowing real time tracing

//ignore, was used when data was baked in
    input wire [5:0] operand_a,
    input wire [5:0] operand_b,

    // Instruction RAM write ports
    input wire        instr_we,
    input wire [7:0]  instr_waddr,
    input wire [15:0] instr_wdata,

    // Core 0's private data-memory ports
    output wire [12:0] mem_raddr,//address requested from core 0, to read main darta from memory
    input  wire [7:0] mem_rdata,//data from main memory

    // Core 1's private data-memory ports (each core owns one BRAM copy;
    // the DMA broadcasts the payload into both)
    output wire [12:0] mem_raddr_1,
    input  wire [7:0]  mem_rdata_1,

    // Core 0's global-memory port (to the SDRAM arbiter in top.sv)
    output wire        g0_req,
    output wire        g0_we,
    output wire [20:0] g0_addr,
    output wire [31:0] g0_wdata,
    output wire [3:0]  g0_wbe,
    input  wire        g0_ack,
    input  wire        g0_rvalid,
    input  wire [31:0] g0_rdata,
    input  wire        g0_done,
    // Core 1's global-memory port (to the SDRAM arbiter in top.sv)
    output wire        g1_req,
    output wire        g1_we,
    output wire [20:0] g1_addr,
    output wire [31:0] g1_wdata,
    output wire [3:0]  g1_wbe,
    input  wire        g1_ack,
    input  wire        g1_rvalid,
    input  wire [31:0] g1_rdata,
    input  wire        g1_done,
    output wire       emit_valid,
    output wire [7:0] emit_data,
    input  wire       emit_ready,

    output wire        mem_we,//if core 0 executes a write insturction, it is enabled
    output wire [12:0] mem_waddr, //address requested from core 0, to write main darta to memory
    output wire [7:0]  mem_wdata, //data to be written to main memory from core 0

    output wire        mem_we_1,
    output wire [12:0] mem_waddr_1,
    output wire [7:0]  mem_wdata_1
);
//outputs from dispatcher, core begins execution
    wire core_0_start, core_1_start;
    wire core_0_done, core_1_done;
    //infroms core which block of data it is processing
    wire [7:0] core_0_id, core_1_id;
    wire core_0_blk_reset, core_1_blk_reset; // per-block core reset from the dispatcher
    wire core_0_busy, core_1_busy;
    wire [7:0] emit_block;                   // lowest unfinished block: owns the UART

//grid scheduler: hands out grid_dim blocks to whichever core is free, resets a
//core between blocks, and owns `done` (high once every block has finished)
    dispatcher main_dispatcher (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .grid_dim(grid_dim),
        .cluster(cluster),
        .core_0_done(core_0_done),
        .core_1_done(core_1_done),
        .core_0_reset(core_0_blk_reset),
        .core_0_start(core_0_start),
        .core_0_id(core_0_id),
        .core_1_reset(core_1_blk_reset),
        .core_1_start(core_1_start),
        .core_1_id(core_1_id),
        .core_0_busy(core_0_busy),
        .core_1_busy(core_1_busy),
        .emit_block(emit_block),
        .done(done)
    );

    // ---- the cluster link between the two cores: distributed shared memory
    //      (each core's loads/stores into the other's), the cluster barrier ----
    wire        c0_arr, c1_arr;
    wire        c0_pr_req, c1_pr_req, c0_pr_ack, c1_pr_ack;
    wire [7:0]  c0_pr_addr, c1_pr_addr;
    wire [31:0] c0_pr_data, c1_pr_data;
    wire        c0_pw_req, c1_pw_req, c0_pw_ack, c1_pw_ack;
    wire [9:0]  c0_pw_addr, c1_pw_addr;
    wire [15:0] c0_pw_data, c1_pw_data;

    // The effective gridDim kernels read with GDIM (0 encodes the legacy 2)
    wire [7:0] grid_dim_eff = (grid_dim == 8'd0) ? 8'd2 : grid_dim;


    wire [7:0] core_0_instruction_address; //program counter output channel of core 0
    wire [15:0] current_instruction;//current instruction

    assign debug_instruction = current_instruction;//debugging

    program_memory rom (
        .clk(clk),
        // Listen to Core 0's PC
        .address(core_0_instruction_address),
        // Output the 16-bit instruction
        .instruction(current_instruction),
        // Live operands patched into the kernel
        .operand_a(operand_a),
        .operand_b(operand_b),
        .we(instr_we),
        .waddr(instr_waddr),
        .wdata(instr_wdata)
    );

    // Core 1's own copy of the kernel ROM. The cores run independent PCs, so
    // they can't share the single BRAM read port; duplicating the small ROM
    // is the cheapest second port.
    wire [7:0]  core_1_instruction_address;
    wire [15:0] current_instruction_1;

    program_memory rom_1 (
        .clk(clk),
        .address(core_1_instruction_address),
        .instruction(current_instruction_1),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .we(instr_we),
        .waddr(instr_waddr),
        .wdata(instr_wdata)
    );


    // Per-core emit handshakes, arbitrated onto the single UART (FSM below)
    wire       c0_emit_valid, c1_emit_valid;
    wire [7:0] c0_emit_data,  c1_emit_data;
    wire       c0_emit_ready, c1_emit_ready;

    // COMPUTE CORE 0 (Fully Wired)
    core #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .WARPS_PER_CORE(WARPS_PER_CORE),
        .BLOCK_DIM(BLOCK_DIM),
        .TC_ENABLE(TC_ENABLE), .TC_KINDS(TC_KINDS),
        .TMA_ENABLE(TMA_ENABLE), .GMEM_ENABLE(GMEM_ENABLE)
    ) compute_core_0 (
        .clk(clk),
        .reset(reset || core_0_blk_reset),
        .start(core_0_start),
        .block_id(core_0_id),
        .grid_dim(grid_dim_eff),
        .done(core_0_done),
        .cluster_mode(cluster), .peer_arrived(c1_arr), .cbar_arrived(c0_arr),
        .pr_req(c0_pr_req), .pr_addr(c0_pr_addr), .pr_ack(c0_pr_ack), .pr_data(c0_pr_data),
        .xr_req(c1_pr_req), .xr_addr(c1_pr_addr), .xr_ack(c1_pr_ack), .xr_data(c1_pr_data),
        .pw_req(c0_pw_req), .pw_addr(c0_pw_addr), .pw_data(c0_pw_data), .pw_ack(c0_pw_ack),
        .xw_req(c1_pw_req), .xw_addr(c1_pw_addr), .xw_data(c1_pw_data), .xw_ack(c1_pw_ack),

        // NEW: Plug into the ROM!
        .instruction_address(core_0_instruction_address),
        .current_instruction(current_instruction),

        .g_req(g0_req), .g_we(g0_we), .g_addr(g0_addr), .g_wdata(g0_wdata), .g_wbe(g0_wbe),
        .g_ack(g0_ack), .g_rvalid(g0_rvalid), .g_rdata(g0_rdata), .g_done(g0_done),
        // Expose the result to the top level
        .result(result),
        .debug_core_state(debug_core_state),

        // Data memory read port
        .mem_raddr(mem_raddr),
        .mem_rdata(mem_rdata),

        // Memory-mapped emit (arbitrated below: core 0's bytes go first)
        .emit_valid(c0_emit_valid),
        .emit_data(c0_emit_data),
        .emit_ready(c0_emit_ready),

        // Data-memory write port
        .mem_we(mem_we),
        .mem_waddr(mem_waddr),
        .mem_wdata(mem_wdata)
    );

    // COMPUTE CORE 1 (own ROM copy + own data-memory copy). Its emit goes
    // through the same UART, after core 0's bytes (see the emit FSM below);
    // until then its LSU just stalls on the handshake.
    core #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .WARPS_PER_CORE(WARPS_PER_CORE),
        .BLOCK_DIM(BLOCK_DIM),
        .TC_ENABLE(TC_ENABLE), .TC_KINDS(TC_KINDS),
        .TMA_ENABLE(TMA_ENABLE), .GMEM_ENABLE(GMEM_ENABLE)
    ) compute_core_1 (
        .clk(clk),
        .reset(reset || core_1_blk_reset),
        .start(core_1_start),
        .block_id(core_1_id),
        .grid_dim(grid_dim_eff),
        .done(core_1_done),
        .cluster_mode(cluster), .peer_arrived(c0_arr), .cbar_arrived(c1_arr),
        .pr_req(c1_pr_req), .pr_addr(c1_pr_addr), .pr_ack(c1_pr_ack), .pr_data(c1_pr_data),
        .xr_req(c0_pr_req), .xr_addr(c0_pr_addr), .xr_ack(c0_pr_ack), .xr_data(c0_pr_data),
        .pw_req(c1_pw_req), .pw_addr(c1_pw_addr), .pw_data(c1_pw_data), .pw_ack(c1_pw_ack),
        .xw_req(c0_pw_req), .xw_addr(c0_pw_addr), .xw_data(c0_pw_data), .xw_ack(c0_pw_ack),
        .instruction_address(core_1_instruction_address),
        .current_instruction(current_instruction_1),
        .g_req(g1_req), .g_we(g1_we), .g_addr(g1_addr), .g_wdata(g1_wdata), .g_wbe(g1_wbe),
        .g_ack(g1_ack), .g_rvalid(g1_rvalid), .g_rdata(g1_rdata), .g_done(g1_done),
        .result(),
        .debug_core_state(),
        .mem_raddr(mem_raddr_1),
        .mem_rdata(mem_rdata_1),
        .emit_valid(c1_emit_valid),
        .emit_data(c1_emit_data),
        .emit_ready(c1_emit_ready),
        .mem_we(mem_we_1),
        .mem_waddr(mem_waddr_1),
        .mem_wdata(mem_wdata_1)
    );

    // ------------------------------------------------------------------
    // Emit path: stream the kernels' STR-to-63 bytes straight to the host.
    //
    // The UART belongs to the core running the lowest unfinished block
    // (emit_block, from the dispatcher). A core running a later block stalls
    // on its first emit until every earlier block has finished, so the reply
    // is each block's bytes in blockIdx order, whichever core ran it. A
    // block's last byte is always acked before its RET (an emit stalls the
    // warp until acked), so ownership never moves mid-byte.
    //
    // Kernels frame their own output (the demo convention is a 1-byte length
    // followed by that many result bytes) so the host knows where each
    // block's output ends.
    // ------------------------------------------------------------------
    wire own_0 = core_0_busy && (core_0_id == emit_block);
    wire own_1 = core_1_busy && (core_1_id == emit_block);

    assign emit_valid = own_0 ? c0_emit_valid
                      : own_1 ? c1_emit_valid
                      :         1'b0;
    assign emit_data  = own_0 ? c0_emit_data : c1_emit_data;
    assign c0_emit_ready = own_0 && emit_ready;
    assign c1_emit_ready = own_1 && emit_ready;

endmodule
