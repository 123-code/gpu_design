`default_nettype none
`timescale 1ns/1ns

module core #(
    parameter THREADS_PER_BLOCK = 4, // lanes per warp (the warp size)
    parameter WARPS_PER_CORE = 2,    // Stage 2: Multiple warps for latency hiding
    parameter BLOCK_DIM = THREADS_PER_BLOCK, // launch size: how many threads this block runs
    parameter ADDR_BITS = 13,        // width of data memory address
    parameter DATA_BITS = 16         // register/ALU datapath width (memory stays byte-wide)
) (
    input wire clk,//clock
    input wire reset,//reset signal
    input wire start,//cycle pulse from dispatcher, when 1, core begins execution
    input wire [7:0] block_id,//8 bit identfier, which block of data is this core processing
    input wire [7:0] grid_dim,//blocks in the launch (%gridDim, read with GDIM)

    // ---- cluster (the other core, when the launch pairs blocks) ----
    input  wire        cluster_mode,
    input  wire        peer_arrived,     // peer parked at its CBAR
    output wire        cbar_arrived,
    // our loads from the peer's shared memory (req held until ack)
    output wire        pr_req,
    output wire [7:0]  pr_addr,
    input  wire        pr_ack,
    input  wire [31:0] pr_data,
    // the peer's loads from ours
    input  wire        xr_req,
    input  wire [7:0]  xr_addr,
    output reg         xr_ack,
    output wire [31:0] xr_data,
    // our stores into the peer's shared memory (taken the same cycle)
    output wire        pw_req,
    output wire [9:0]  pw_addr,
    output wire [15:0] pw_data,
    input  wire        pw_ack,
    // the peer's stores into ours
    input  wire        xw_req,
    input  wire [9:0]  xw_addr,
    input  wire [15:0] xw_data,
    output wire        xw_ack,
    output wire done,//when 1, core has finished processing

//dtata memory read (since multiple threads want to read simultaneously, read requests are serialized by arbiter)
    output wire [ADDR_BITS-1:0] mem_raddr,//address
    input  wire [7:0]           mem_rdata,//data

    // Memory-mapped emit (thread 0's STR to offset 63 -> UART TX)
    output wire                 emit_valid,
    output wire [7:0]           emit_data,
    input  wire                 emit_ready,

    // data write from threads back to ram
    output wire                 mem_we,//write eneble
    output wire [ADDR_BITS-1:0]  mem_waddr,//ram address where data will be stored
    output wire [7:0]            mem_wdata,//data to be stored in memory


    output wire [7:0] instruction_address, // Asking the ROM for code
    input wire [15:0] current_instruction, // Receiving the code from ROM

    // Global-memory port (SDRAM, shared by every core; see top.sv)
    output wire        g_req,
    output wire        g_we,
    output wire [20:0] g_addr,
    output wire [31:0] g_wdata,
    output wire [3:0]  g_wbe,
    input  wire        g_ack,
    input  wire        g_rvalid,
    input  wire [31:0] g_rdata,
    input  wire        g_done,

    // Debug tap: thread 0's R3 (the accumulator) for the LED display
    output wire [7:0] result,
    // Debug tap: the scheduler FSM state, for hardware bring-up visibility
    output wire [2:0] debug_core_state
);

    // 4-bit pipeline state, driven by the scheduler. Must match scheduler.sv:
    //   IDLE=0000 SELECT_WARP=0001 FETCH=0010 DECODE=0011 REQUEST=0100
    //   WAIT=0101 EXECUTE=0110 UPDATE=0111 DONE=1000
    wire [3:0] core_state;
    assign debug_core_state = core_state[2:0];
    wire [1:0] lsu_states [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0] active_mask [WARPS_PER_CORE-1:0];
    // Packed views for the scheduler's ports (see scheduler.sv)
    wire [WARPS_PER_CORE*THREADS_PER_BLOCK*2-1:0] lsu_states_flat;
    wire [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0]   active_mask_flat;
    wire [WARPS_PER_CORE*8-1:0]                   warp_pc_flat;

    // ==========================================
    // DECODER DATAPATH WIRES (real ports from decoder.sv)
    // ==========================================
    wire [3:0] decoded_rd_address;
    wire [3:0] decoded_rs_address;
    wire [3:0] decoded_rt_address;
    wire [2:0] decoded_nzp;
    wire [DATA_BITS-1:0] decoded_immediate;

    wire decoded_reg_write_enable;
    wire decoded_mem_read_enable;
    wire decoded_mem_write_enable;
    wire decoded_nzp_write_enable;
    wire [1:0] decoded_reg_input_mux;
    wire [1:0] decoded_alu_arithmetic_mux;
    wire decoded_alu_output_mux;
    wire decoded_pc_mux;
    wire decoded_ret;
    wire decoded_mac_load;
    wire decoded_base_add;
    wire decoded_wbase_add;
    wire decoded_fc_clear;
    wire decoded_fc_mac;
    wire decoded_fc_arg;
    wire decoded_fc_read;
    wire decoded_fc_acc;
    wire decoded_fc_out;
    wire [2:0] decoded_fc_shift;
    wire decoded_id_read;
    wire decoded_lui;
    wire decoded_sync; // NEW
    wire decoded_shared;   // LDS/STS
    wire decoded_bar;      // BAR
    wire decoded_mma, decoded_tcfg, decoded_tld, decoded_tldq, decoded_tc_op;
    wire tc_busy;
    wire decoded_tma, decoded_tmawait, decoded_tma_global;
    wire decoded_global;   // LDG/STG
    wire decoded_cbar, decoded_mma2;
    wire tma_busy;
    wire [1:0] decoded_mac_byte; // which 8-bit slice of the 32-bit MAC/FC result

    wire current_warp;
    wire [WARPS_PER_CORE-1:0] warp_emit;   // per-warp: thread 0 has a UART emit in flight
    wire [THREADS_PER_BLOCK-1:0] branch_votes;
    wire [THREADS_PER_BLOCK-1:0] all_branch_votes [WARPS_PER_CORE-1:0];
    assign branch_votes = all_branch_votes[current_warp];

    wire [7:0] warp_pc [WARPS_PER_CORE-1:0];

    // ==========================================
    // INSTANTIATE THE (REAL) DECODER
    // ==========================================
    decoder #(.DATA_BITS(DATA_BITS)) core_decoder (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .instruction(current_instruction),

        .decoded_rd_address(decoded_rd_address),
        .decoded_rs_address(decoded_rs_address),
        .decoded_rt_address(decoded_rt_address),
        .decoded_nzp(decoded_nzp),
        .decoded_immediate(decoded_immediate),

        .decoded_reg_write_enable(decoded_reg_write_enable),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_nzp_write_enable(decoded_nzp_write_enable),

        .decoded_reg_input_mux(decoded_reg_input_mux),
        .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
        .decoded_alu_output_mux(decoded_alu_output_mux),
        .decoded_pc_mux(decoded_pc_mux),
        .decoded_ret(decoded_ret),
        .decoded_mac_load(decoded_mac_load),
        .decoded_base_add(decoded_base_add),
        .decoded_wbase_add(decoded_wbase_add),
        .decoded_fc_clear(decoded_fc_clear),
        .decoded_fc_mac(decoded_fc_mac),
        .decoded_fc_arg(decoded_fc_arg),
        .decoded_fc_read(decoded_fc_read),
        .decoded_fc_acc(decoded_fc_acc),
        .decoded_fc_out(decoded_fc_out),
        .decoded_fc_shift(decoded_fc_shift),
        .decoded_id_read(decoded_id_read),
        .decoded_lui(decoded_lui),
        .decoded_sync(decoded_sync),
        .decoded_shared(decoded_shared),
        .decoded_bar(decoded_bar),
        .decoded_mma(decoded_mma),
        .decoded_tcfg(decoded_tcfg),
        .decoded_tld(decoded_tld),
        .decoded_tldq(decoded_tldq),
        .decoded_tc_op(decoded_tc_op),
        .decoded_tma(decoded_tma),
        .decoded_tmawait(decoded_tmawait),
        .decoded_tma_global(decoded_tma_global),
        .decoded_global(decoded_global),
        .decoded_cbar(decoded_cbar),
        .decoded_mma2(decoded_mma2),
        .decoded_mac_byte(decoded_mac_byte)
    );

    // ==========================================
    // THE SCHEDULER
    // ==========================================
    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .WARPS_PER_CORE(WARPS_PER_CORE),
        .BLOCK_DIM(BLOCK_DIM)
    ) core_scheduler (
        .clk(clk),
        .reset(reset),
        .start(start),
        .decoded_ret(decoded_ret), // It is finally alive!
        .lsu_state_flat(lsu_states_flat),

        .decoded_sync(decoded_sync),
        .decoded_bar(decoded_bar),
        .decoded_cbar(decoded_cbar),
        .cluster_mode(cluster_mode),
        .peer_arrived(peer_arrived),
        .cbar_arrived(cbar_arrived),
        .decoded_tc_op(decoded_tc_op),
        .tc_busy(tc_busy),
        .decoded_tma_op(decoded_tma || decoded_tmawait),
        .tma_busy(tma_busy),
        .decoded_pc_mux(decoded_pc_mux),
        .decoded_immediate(decoded_immediate[7:0]), // branch target is PC-domain (8-bit)
        .branch_votes(branch_votes),
        // LSU-touching instruction? Lets the scheduler skip REQUEST/WAIT for
        // compute-only ops (LDR/STR/emit decode these enables).
        .decoded_mem_op(decoded_mem_read_enable || decoded_mem_write_enable),
        .instruction(current_instruction),
        .fetch_addr(fetch_addr),
        .warp_emit(warp_emit),

        .current_warp(current_warp),
        .warp_pc_flat(warp_pc_flat),

        .core_state(core_state),
        .done(done),
        .active_mask_flat(active_mask_flat)
    );

    genvar fw, fi;
    generate
        for (fw = 0; fw < WARPS_PER_CORE; fw = fw + 1) begin : unflatten
            assign warp_pc[fw]     = warp_pc_flat[fw*8 +: 8];
            assign active_mask[fw] = active_mask_flat[fw*THREADS_PER_BLOCK +: THREADS_PER_BLOCK];
            for (fi = 0; fi < THREADS_PER_BLOCK; fi = fi + 1) begin : flat_lsu
                assign lsu_states_flat[(fw*THREADS_PER_BLOCK+fi)*2 +: 2] = lsu_states[fw][fi];
            end
        end
    endgenerate

    // ==========================================
    // THE THREAD GRID
    // ==========================================
    wire [DATA_BITS-1:0] rs_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [DATA_BITS-1:0] rt_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [DATA_BITS-1:0] alu_out_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [DATA_BITS-1:0] lsu_out_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] reg3_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0]; // debug tap (low byte of R3)

    // Expose Warp 0 Thread 0's accumulator as this core's result
    assign result = reg3_bus[0][0];

    // PC bus
    wire [7:0] pc_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] next_pc_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];

    // Shared ALU inputs and outputs (Multiplexed by current_warp)
    wire [DATA_BITS-1:0] active_rs [THREADS_PER_BLOCK-1:0];
    wire [DATA_BITS-1:0] active_rt [THREADS_PER_BLOCK-1:0];
    wire [DATA_BITS-1:0] active_alu_out [THREADS_PER_BLOCK-1:0];

    // Flattened arrays for LSU Arbiter
    // LSU addresses are 16 bits (the global space is 64 KB); main memory
    // uses the low ADDR_BITS, shared memory the low 10.
    localparam LA = 16;
    wire [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0] lsu_req;
    wire [LA-1:0] lsu_addr [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0];
    wire [1:0] lsu_space [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0];
    wire [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0] arb_ready;
    wire [15:0] arb_rdata [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0];

    // Per-warp/thread wires for LSU
    wire lsu_mem_valid [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [1:0] lsu_mem_space [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [LA-1:0] lsu_mem_addr [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_mem_write_data [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];

    wire lsu_emit_valid [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_emit_data [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];

    // ---- Emit ownership latch ----
    // A warp emits (thread 0 STR to offset 63) by raising lsu_emit_valid[w][0]
    // and holding it until emit_ready. The scheduler can context-switch away
    // mid-handshake, so route the UART by a LATCHED owner (held until the byte
    // is acked) rather than current_warp, and steer emit_ready to that owner
    // only — otherwise a context switch tears/misroutes the byte. (Hardcoded for
    // 2 warps, matching the rest of the multi-warp logic.)
    reg emit_owned;
    reg emit_owner;                  // 1-bit owner id (WARPS_PER_CORE <= 2)
    integer ew;
    reg     ew_found;
    always @(posedge clk) begin
        if (reset) begin
            emit_owned <= 1'b0;
            emit_owner <= 1'b0;
        end else if (!emit_owned) begin
            // Lowest-index warp with thread 0's emit valid claims the UART (loop
            // form so it works for any WARPS_PER_CORE, including 1).
            ew_found = 1'b0;
            for (ew = 0; ew < WARPS_PER_CORE; ew = ew + 1) begin
                if (!ew_found && lsu_emit_valid[ew][0]) begin
                    emit_owned <= 1'b1;
                    emit_owner <= ew[0];
                    ew_found = 1'b1;
                end
            end
        end else if (emit_ready) begin
            emit_owned <= 1'b0;                 // byte acked -> release the UART
        end
    end
    assign emit_valid = emit_owned && lsu_emit_valid[emit_owner][0];
    assign emit_data  = lsu_emit_data[emit_owner][0];

    // Per-warp emit-in-flight flag for the scheduler's emit-stall (thread 0).
    genvar gw;
    generate
        for (gw = 0; gw < WARPS_PER_CORE; gw = gw + 1) begin : warp_emit_gen
            assign warp_emit[gw] = lsu_emit_valid[gw][0];
        end
    endgenerate

    wire lsu_we [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [1:0] lsu_we_space [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [LA-1:0] lsu_waddr [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [15:0] lsu_wdata [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];

    // Per-lane write requests serialized onto the single memory write port by the
    // write arbiter (mirrors the read arbiter above). This is what lets every lane
    // store its own result instead of only thread 0 (e.g. one neuron per lane).
    wire [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0] we_req_flat;
    wire [LA-1:0]        waddr_flat [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0];
    wire [15:0]          wdata_flat [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0];
    wire [1:0]           wspace_flat [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0];

    // ==========================================
    // L1 CACHE + GLOBAL PORT
    // ==========================================
    // LDG/STG go through a 256-byte L1 (l1_cache.sv). The L1 and the copy
    // engine (TMAG line reads) share the core's one port to global memory.
    wire        l1_rd_req, l1_rd_ack, l1_wr_req, l1_wr_ack;
    wire [15:0] l1_rd_addr, l1_rd_data, l1_wr_addr, l1_wr_data;
    wire        l1m_req, l1m_we, l1m_ack, l1m_rvalid, l1m_done;
    wire [20:0] l1m_addr;
    wire [31:0] l1m_wdata;
    wire [3:0]  l1m_wbe;
    wire [15:0] l1_hits, l1_misses;
    l1_cache u_l1 (
        .clk(clk), .reset(reset),
        .rd_req(l1_rd_req), .rd_addr(l1_rd_addr), .rd_ack(l1_rd_ack), .rd_data(l1_rd_data),
        .wr_req(l1_wr_req), .wr_addr(l1_wr_addr), .wr_data(l1_wr_data), .wr_ack(l1_wr_ack),
        .m_req(l1m_req), .m_we(l1m_we), .m_addr(l1m_addr), .m_wdata(l1m_wdata), .m_wbe(l1m_wbe),
        .m_ack(l1m_ack), .m_rvalid(l1m_rvalid), .m_rdata(g_rdata), .m_done(l1m_done),
        .hits(l1_hits), .misses(l1_misses)
    );
    wire        engm_req, engm_ack, engm_rvalid, engm_done;
    wire [20:0] engm_addr;
    wire [1:0]  gp_ack, gp_rvalid, gp_done;
    wire [20:0] gp_addr  [1:0];
    wire [31:0] gp_wdata [1:0];
    wire [3:0]  gp_wbe   [1:0];
    assign gp_addr[0] = l1m_addr;   assign gp_addr[1] = engm_addr;
    assign gp_wdata[0] = l1m_wdata; assign gp_wdata[1] = 32'd0;
    assign gp_wbe[0] = l1m_wbe;     assign gp_wbe[1] = 4'd0;
    mem_arb #(.N(2)) u_gport (
        .clk(clk), .reset(reset),
        .c_req({engm_req, l1m_req}),
        .c_we({1'b0, l1m_we}),
        .c_addr(gp_addr),
        .c_wdata(gp_wdata),
        .c_wbe(gp_wbe),
        .c_ack(gp_ack), .c_rvalid(gp_rvalid), .c_done(gp_done),
        .m_req(g_req), .m_we(g_we), .m_addr(g_addr), .m_wdata(g_wdata), .m_wbe(g_wbe),
        .m_ack(g_ack), .m_rvalid(g_rvalid), .m_done(g_done)
    );
    assign {engm_ack, l1m_ack}       = gp_ack;
    assign {engm_rvalid, l1m_rvalid} = gp_rvalid;
    assign {engm_done, l1m_done}     = gp_done;
    wire [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0] wgrant_flat;

    // ==========================================
    // SHARED MEMORY (per core, CUDA __shared__)
    // ==========================================
    // 1 KB scratchpad the threads reach with LDS/STS (16-bit halfwords) and
    // the tensor core reads 32-bit operand words from. Its read port is
    // shared between the LSU read arbiter and the tensor core; its write
    // port belongs to the LSU write arbiter.
    wire        sh_we;
    wire [7:0]  sh_waddr;
    wire [31:0] sh_wdata;
    wire [3:0]  sh_wbe;
    wire        arb_sh_we;              // LSU write arbiter's shared port
    wire [7:0]  arb_sh_waddr;
    wire [31:0] arb_sh_wdata;
    wire [3:0]  arb_sh_wbe;
    wire        eng_sh_we;              // copy engine's
    wire [7:0]  eng_sh_waddr;
    wire [31:0] eng_sh_wdata;
    wire [3:0]  eng_sh_wbe;
    wire        eng_wr_req;             // engine owns the write port while active
    // The engine's first write comes >= 2 cycles after it raised eng_wr_req
    // (which holds the write arbiter), so the two never write together.
    assign sh_we    = eng_sh_we | arb_sh_we;
    assign sh_waddr = eng_sh_we ? eng_sh_waddr : arb_sh_waddr;
    assign sh_wdata = eng_sh_we ? eng_sh_wdata : arb_sh_wdata;
    assign sh_wbe   = eng_sh_we ? eng_sh_wbe   : arb_sh_wbe;

    // main-memory read port: copy engine or LSU read arbiter
    wire [ADDR_BITS-1:0] arb_mem_raddr;
    wire                 arb_mem_busy;
    wire                 eng_rd_req, eng_rd_gnt;
    wire [ADDR_BITS-1:0] eng_rd_addr;
    assign eng_rd_gnt = eng_rd_req && !arb_mem_busy;
    assign mem_raddr  = eng_rd_gnt ? eng_rd_addr : arb_mem_raddr;
    wire [7:0]  sh_raddr;
    wire [31:0] sh_rdata;
    wire [7:0]  arb_sh_raddr;
    wire        arb_sh_busy;
    wire        sh_rd_hold;             // another unit wants the read port
    wire        sh_rd_gnt;              // ... and has it this cycle
    wire [7:0]  unit_sh_raddr;          // that unit's word address

    shared_memory #(.WORDS(256)) u_smem (
        .clk(clk),
        .we(sh_we), .waddr(sh_waddr), .wdata(sh_wdata), .wbe(sh_wbe),
        .raddr(sh_raddr), .rdata(sh_rdata)
    );
    // The borrowing unit gets the port once no LSU shared read is in flight
    // (the arbiter stops accepting new requests as soon as it asks).
    assign sh_rd_gnt = sh_rd_hold && !arb_sh_busy;
    // The peer's DSMEM load borrows the port the same way, after the tensor
    // core. xr_ack (with the data) follows a grant by one cycle; the cycle it
    // is high the peer still holds xr_req, so no second grant then.
    wire xr_gnt = xr_req && !sh_rd_hold && !arb_sh_busy && !xr_ack;
    always @(posedge clk) xr_ack <= reset ? 1'b0 : xr_gnt;
    assign xr_data  = sh_rdata;
    assign sh_raddr = sh_rd_gnt ? unit_sh_raddr : xr_gnt ? xr_addr : arb_sh_raddr;

    // Our outgoing DSMEM loads: the LSU arbiter and the tensor core (MMA2)
    // share the one link to the peer. Whoever asks first holds it until ack.
    wire        arb_pr_req, tc_pr_req;
    wire [7:0]  arb_pr_addr, tc_pr_addr;
    reg         pr_lock, pr_own;            // locked to: 0 = arbiter, 1 = TC
    wire        pr_sel = pr_lock ? pr_own : (tc_pr_req ? 1'b1 : 1'b0);
    assign pr_req  = pr_sel ? tc_pr_req : arb_pr_req;
    assign pr_addr = pr_sel ? tc_pr_addr : arb_pr_addr;
    always @(posedge clk) begin
        if (reset) begin pr_lock <= 1'b0; pr_own <= 1'b0; end
        else if (!pr_lock && pr_req) begin pr_lock <= 1'b1; pr_own <= pr_sel; end
        else if (pr_lock && pr_ack) pr_lock <= 1'b0;
    end
    wire arb_pr_ack = pr_ack && !pr_sel;
    wire tc_pr_ack  = pr_ack &&  pr_sel;

    lsu_write_arbiter #(
        .THREADS(WARPS_PER_CORE * THREADS_PER_BLOCK),
        .ADDR_BITS(LA)
    ) core_lsu_write_arbiter (
        .clk(clk),
        .reset(reset),
        .we_req(we_req_flat),
        .waddr(waddr_flat),
        .wdata(wdata_flat),
        .space(wspace_flat),
        .hold(eng_wr_req),
        .g_wreq(l1_wr_req),
        .g_waddr(l1_wr_addr),
        .g_wdata(l1_wr_data),
        .g_wack(l1_wr_ack),
        .r_wreq(pw_req),
        .r_waddr(pw_addr),
        .r_wdata(pw_data),
        .r_wack(pw_ack),
        .x_wreq(xw_req),
        .x_waddr(xw_addr),
        .x_wdata(xw_data),
        .x_wack(xw_ack),
        .mem_we(mem_we),
        .mem_waddr(mem_waddr),
        .mem_wdata(mem_wdata),
        .sh_we(arb_sh_we),
        .sh_waddr(arb_sh_waddr),
        .sh_wdata(arb_sh_wdata),
        .sh_wbe(arb_sh_wbe),
        .wgrant(wgrant_flat)
    );

    // Shared Arbiter (handles all warps and threads simultaneously)
    lsu_arbiter #(
        .THREADS(WARPS_PER_CORE * THREADS_PER_BLOCK),
        .ADDR_BITS(LA)
    ) core_lsu_arbiter (
        .clk(clk),
        .reset(reset),
        .req(lsu_req),
        .addr(lsu_addr),
        .space(lsu_space),
        .hold(sh_rd_hold || eng_rd_req || xr_req),
        .sh_busy(arb_sh_busy),
        .mem_busy(arb_mem_busy),
        .g_req(l1_rd_req),
        .g_addr(l1_rd_addr),
        .g_ack(l1_rd_ack),
        .g_rdata(l1_rd_data),
        .r_req(arb_pr_req),
        .r_addr(arb_pr_addr),
        .r_ack(arb_pr_ack),
        .r_data(pr_data),
        .mem_raddr(arb_mem_raddr),
        .mem_rdata(mem_rdata),
        .sh_raddr(arb_sh_raddr),
        .sh_rdata(sh_rdata),
        .ready(arb_ready),
        .rdata(arb_rdata)
    );

    // The scheduler drives the instruction ROM: the current warp's PC, or in
    // UPDATE the next warp's (fetch overlapped with writeback)
    wire [7:0] fetch_addr;
    assign instruction_address = fetch_addr;

    // Operand-read addresses from the raw instruction word (for DECODE).
    // LUI (MOV with rs field 4) reads its own Rd, which it shifts.
    wire [2:0] fetch_rs = (current_instruction[15:12] == 4'b0010 && current_instruction[8:6] == 3'b100)
                        ? current_instruction[11:9] : current_instruction[8:6];
    wire [2:0] fetch_rt = current_instruction[2:0];

    // ==========================================
    // THE VECTOR MAC FUNCTIONAL UNIT (shared, core-level)
    // ==========================================
    // vector_mac is a STATIC 8-lane multiply-accumulate: 8 parallel signed
    // multipliers + a fixed adder tree (see vector_mac.sv). It always sums all 8
    // lanes; there is no programmable length. Operands reach it through two 8-slot
    // buffers below: each MACL pushes one (pixel=rs, weight=rt) PAIR and bumps
    // mac_wptr (capped at 8); MAC then fires and reads the 8-lane dot product.
    // Push up to 8 pairs before firing; unused slots keep their previous value and
    // still contribute, so zero them (or push a full 8) if you need a shorter dot
    // product. Thread 0 drives the buffers (SIMT-uniform). For an arbitrary-length
    // accumulation use the FC unit instead (fc_mac.sv: FMAC accumulates per cycle).
    localparam UPDATE_STATE = 4'b0111;
    // Small operand buffers (stay in FFs: written at a variable index but read at
    // constant indices by vector_mac, so GowinSynthesis does not RAM-infer them).
    reg  [7:0] mac_buf [0:8];    // 9 pixel slots (3x3 conv window)
    reg  [7:0] weight_buf [0:8]; // 9 weight slots
    reg  [3:0] mac_wptr;
    wire       mac_fire = decoded_reg_write_enable && (decoded_reg_input_mux == 2'b11)
                          && !decoded_fc_read;

    integer mb;
    always @(posedge clk) begin
        if (reset) begin
            mac_wptr <= 4'd0;
            // Zero all 9 operand slots so lanes a kernel doesn't fill contribute
            // 0 (not stale/X) to the dot product. Matters for < 9-tap users like
            // mac32/nn now that the MAC is 9-lane.
            for (mb = 0; mb < 9; mb = mb + 1) begin
                mac_buf[mb]    <= 8'd0;
                weight_buf[mb] <= 8'd0;
            end
        end else if (core_state == UPDATE_STATE) begin
            if (decoded_mac_load && mac_wptr < 4'd9) begin
                mac_buf[mac_wptr] <= rs_bus[current_warp][0][7:0];     // push a pixel from rs register (8-bit MAC lane)
                weight_buf[mac_wptr] <= rt_bus[current_warp][0][7:0];  // push a weight from rt register (8-bit MAC lane)
                mac_wptr <= mac_wptr + 4'd1;
            end else if (mac_fire) begin
                mac_wptr <= 4'd0;                      // consumed -> ready for next window
            end
        end
    end



    wire [31:0] vector_result_32;

    vector_mac u_mac (
        .clk(clk),
        .rst_n(~reset),
        .valid_in(1'b1),
        .px0(mac_buf[0]), .px1(mac_buf[1]), .px2(mac_buf[2]), .px3(mac_buf[3]),
        .px4(mac_buf[4]), .px5(mac_buf[5]), .px6(mac_buf[6]), .px7(mac_buf[7]),
        .px8(mac_buf[8]),
        .w0(weight_buf[0]), .w1(weight_buf[1]), .w2(weight_buf[2]), .w3(weight_buf[3]),
        .w4(weight_buf[4]), .w5(weight_buf[5]), .w6(weight_buf[6]), .w7(weight_buf[7]),
        .w8(weight_buf[8]),
        .result_out(vector_result_32),
        .valid_out()
    );

    // ==========================================
    // THE FC-MAC FUNCTIONAL UNIT (shared, core-level)
    // ==========================================
    // Wide (32-bit) accumulator for the fully-connected layer: thread 0 drives
    // it (SIMT-uniform). FCLR/FMAC act in UPDATE; FRD reads it back through the
    // MAC writeback mux (mux==11 with decoded_fc_read selecting fc over conv).
    wire [31:0] fc_result_32;
    wire [31:0] fc_acc_32;      // raw accumulator, read by FACC
    wire [7:0]  fc_relu_8;      // requantized+ReLU'd neuron output, read by FOUT

    fc_mac u_fc (
        .clk(clk),
        .reset(reset),
        .frst  (decoded_fc_clear && (core_state == UPDATE_STATE)),
        .mac_en(decoded_fc_mac   && (core_state == UPDATE_STATE)),
        .farg  (decoded_fc_arg   && (core_state == UPDATE_STATE)),
        .fout  (decoded_fc_out   && (core_state == UPDATE_STATE)),
        .out_shift(decoded_fc_shift),
        .px(rs_bus[current_warp][0][7:0]),
        .wt(rt_bus[current_warp][0][7:0]),
        .bias_in({{24{rt_bus[current_warp][0][7]}}, rt_bus[current_warp][0][7:0]}), // Sign-extend low byte to 32-bit bias
        .result(fc_result_32),
        .acc_out(fc_acc_32),
        .relu_out(fc_relu_8)
    );

    // Writeback source for the shared MAC mux: conv MAC normally, FC readout on FRD.
    // Both units produce a 32-bit result; decoded_mac_byte (from MAC Rd,#n) picks
    // which 8-bit slice reaches the 8-bit register file, so software can pull the
    // whole 32-bit value out across four reads. Bare MAC / FBEST => byte 0 (LSB).
    // FACC (decoded_fc_acc) reads the raw accumulator; FBEST reads best_idx;
    // everything else reads the 9-lane conv MAC.
    wire [31:0] fc_readback_32 = decoded_fc_out ? {24'd0, fc_relu_8}
                               : decoded_fc_acc ? fc_acc_32
                               :                  fc_result_32;
    wire [31:0] mac_or_fc_result_32 = decoded_fc_read ? fc_readback_32 : vector_result_32;
    wire [7:0] mac_or_fc_result =
          (decoded_mac_byte == 2'd0) ? mac_or_fc_result_32[7:0]
        : (decoded_mac_byte == 2'd1) ? mac_or_fc_result_32[15:8]
        : (decoded_mac_byte == 2'd2) ? mac_or_fc_result_32[23:16]
        :                              mac_or_fc_result_32[31:24];
    // Zero-extend the selected byte to the register width (byte-select readback
    // unchanged: software still pulls the 32-bit MAC result out one byte at a time).
    wire [DATA_BITS-1:0] mac_result_ext = {{(DATA_BITS-8){1'b0}}, mac_or_fc_result};

    // ==========================================
    // TENSOR CORE + TMEM (shared, core-level)
    // ==========================================
    // MMA operands are shared-memory ADDRESSES in thread 0's rs/rt (uniform
    // across the warp, like a tcgen05 descriptor); the result lands in TMEM.
    // The unit borrows the shared-memory read port while it stages A and B.
    wire [127:0] tld_data;
    wire [4:0]   tc_qshift;
    tensor_core #(.TMEM_COLS(16)) u_tc (
        .clk(clk),
        .reset(reset),
        .start(decoded_mma && core_state == UPDATE_STATE),
        .a_addr(rs_bus[current_warp][0][9:0]),
        .b_addr(rt_bus[current_warp][0][9:0]),
        .d_tile(decoded_immediate[4:3]),
        .accumulate(decoded_immediate[5]),
        .pair(decoded_mma2 && cluster_mode),
        .rank(block_id[0]),
        .cfg_we(decoded_tcfg && core_state == UPDATE_STATE),
        .cfg_data(rs_bus[current_warp][0]),
        .busy(tc_busy),
        .sh_req(sh_rd_hold),
        .sh_gnt(sh_rd_gnt),
        .sh_raddr(unit_sh_raddr),
        .sh_rdata(sh_rdata),
        .pr_req(tc_pr_req),
        .pr_addr(tc_pr_addr),
        .pr_ack(tc_pr_ack),
        .pr_data(pr_data),
        .tld_col(decoded_immediate[5:2]),
        .tld_data(tld_data),
        .qshift(tc_qshift)
    );

    // ==========================================
    // BULK COPY ENGINE (TMA)
    // ==========================================
    // TMA Rs,Rt,#n: n words (imm[5:3], 0 = 8) from data memory [Rs] to shared
    // memory [Rt], in the background. Addresses come from thread 0 (uniform).
    copy_engine #(.ADDR_BITS(ADDR_BITS)) u_tma (
        .clk(clk),
        .reset(reset),
        .start(decoded_tma && core_state == UPDATE_STATE),
        .src(rs_bus[current_warp][0][ADDR_BITS-1:0]),
        .dst(rt_bus[current_warp][0][9:0]),
        .nwords((decoded_immediate[5:3] == 3'd0) ? 4'd8 : {1'b0, decoded_immediate[5:3]}),
        .src_global(decoded_tma_global),
        .gsrc(rs_bus[current_warp][0]),
        .busy(tma_busy),
        .m_req(engm_req),
        .m_addr(engm_addr),
        .m_ack(engm_ack),
        .m_rvalid(engm_rvalid),
        .m_rdata(g_rdata),
        .m_done(engm_done),
        .rd_req(eng_rd_req),
        .rd_gnt(eng_rd_gnt),
        .rd_addr(eng_rd_addr),
        .rd_data(mem_rdata),
        .wr_req(eng_wr_req),
        .sh_we(eng_sh_we),
        .sh_waddr(eng_sh_waddr),
        .sh_wdata(eng_sh_wdata),
        .sh_wbe(eng_sh_wbe)
    );

    // Per-lane TLD/TLDQ value: lane i reads TMEM row i (rows 0..3; lanes
    // past the tile read 0).
    wire [DATA_BITS-1:0] tc_lane [THREADS_PER_BLOCK-1:0];
    genvar tl;
    generate
        for (tl = 0; tl < THREADS_PER_BLOCK; tl = tl + 1) begin : tc_lanes
            wire signed [31:0] row = (tl < 4) ? tld_data[(tl % 4)*32 +: 32] : 32'sd0;
            wire signed [31:0] q   = row >>> tc_qshift;
            wire [7:0] q8 = q[31] ? 8'd0 : (|q[30:8]) ? 8'd255 : q[7:0];
            assign tc_lane[tl] = decoded_tldq          ? {{(DATA_BITS-8){1'b0}}, q8}
                               : decoded_immediate[0]  ? row[31:16]
                               :                         row[15:0];
        end
    endgenerate

    genvar w, i;
    generate
        // Shared ALUs across all warps (Time-multiplexed execution units)
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : shared_alus
            assign active_rs[i] = rs_bus[current_warp][i];
            assign active_rt[i] = rt_bus[current_warp][i];

            alu #(.DATA_BITS(DATA_BITS)) thread_alu (
                .clk(clk),
                .opcode(current_instruction[15:12]),
                .imm(decoded_immediate),
                .rs(active_rs[i]),
                .rt(active_rt[i]),
                .alu_out(active_alu_out[i])
            );
        end

        // Independent state for each warp
        for (w = 0; w < WARPS_PER_CORE; w = w + 1) begin : warp_block
            wire warp_active_flag = (current_warp == w);
            for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : thread_block

                localparam flat_id = w * THREADS_PER_BLOCK + i;

                registers #(
                    .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                    // GLOBAL thread index: warp w lane i -> w*warpSize + i.
                    // (warp0 = 0..3, warp1 = 4..7) so the two warps cover
                    // DISTINCT threads instead of redundantly running 0..3.
                    .THREAD_ID(w * THREADS_PER_BLOCK + i),
                    .BLOCK_DIM(BLOCK_DIM),
                    .DATA_BITS(DATA_BITS)
                ) thread_regs (
                    .clk(clk),
                    .reset(reset),
                    .enable(1'b1),
                    .block_id(block_id),
                    .grid_dim(grid_dim),
                    .cluster_rank(cluster_mode && block_id[0]),
                    .core_state(core_state),
                    .thread_active(active_mask[w][i]),
                    .warp_active(warp_active_flag),

                    .decoded_rd_address(decoded_rd_address),
                    .decoded_rs_address(decoded_rs_address),
                    .decoded_rt_address(decoded_rt_address),
                    .fetch_rs_address(fetch_rs),
                    .fetch_rt_address(fetch_rt),

                    .decoded_reg_write_enable(decoded_reg_write_enable),
                    .decoded_reg_input_mux(decoded_reg_input_mux),
                    .decoded_id_read(decoded_id_read),
                    .decoded_lui(decoded_lui),
                    .decoded_immediate(decoded_immediate),

                    .alu_out(active_alu_out[i]), // Fed from the shared ALU!
                    .lsu_out(lsu_out_bus[w][i]),

                    .rs(rs_bus[w][i]),
                    .rt(rt_bus[w][i]),

                    .mac_result(mac_result_ext),
                    .decoded_tc_read(decoded_tld || decoded_tldq),
                    .tc_data(tc_lane[i]),
                    .debug_reg3(reg3_bus[w][i])
                );

                lsu #(.ADDR_BITS(LA), .DATA_BITS(DATA_BITS)) thread_lsu (
                    .clk(clk),
                    .reset(reset),
                    .enable(1'b1),
                    .thread_active(active_mask[w][i]),
                    .warp_active(warp_active_flag),
                    .core_state(core_state),
//decoded_mac_load
                    .decoded_mem_read(decoded_mem_read_enable),
                    .decoded_mem_write(decoded_mem_write_enable),
                    .decoded_base_add(decoded_base_add),
                    .decoded_wbase_add(decoded_wbase_add),
                    .decoded_shared(decoded_shared),
                    .decoded_global(decoded_global),
                    .decoded_immediate(decoded_immediate),

                    .rs(rs_bus[w][i]),
                    .rt(rt_bus[w][i]),

                    .mem_valid(lsu_mem_valid[w][i]),
                    .mem_addr(lsu_mem_addr[w][i]),
                    .mem_space(lsu_mem_space[w][i]),
                    .mem_write_data(lsu_mem_write_data[w][i]),
                    .mem_ready(arb_ready[flat_id]),
                    .mem_read_data(arb_rdata[flat_id]),

                    .we_req(lsu_we[w][i]),
                    .waddr(lsu_waddr[w][i]),
                    .wdata(lsu_wdata[w][i]),
                    .we_space(lsu_we_space[w][i]),
                    .wgrant(wgrant_flat[flat_id]),

                    .emit_valid(lsu_emit_valid[w][i]),
                    .emit_data(lsu_emit_data[w][i]),
                    // Only the warp that currently owns the UART sees the ack.
                    .emit_ready((emit_owned && emit_owner == w) ? emit_ready : 1'b0),

                    .lsu_state(lsu_states[w][i]),
                    .lsu_out(lsu_out_bus[w][i])
                );

                // Tie read-arbiter flattened arrays
                assign lsu_req[flat_id] = lsu_mem_valid[w][i];
                assign lsu_addr[flat_id] = lsu_mem_addr[w][i];
                assign lsu_space[flat_id] = lsu_mem_space[w][i];

                // Tie write-arbiter flattened arrays
                assign we_req_flat[flat_id] = lsu_we[w][i];
                assign waddr_flat[flat_id]  = lsu_waddr[w][i];
                assign wdata_flat[flat_id]  = lsu_wdata[w][i];
                assign wspace_flat[flat_id] = lsu_we_space[w][i];

                pc thread_pc (
                    .clk(clk),
                    .reset(reset),
                    .enable(1'b1),
                    .warp_active(warp_active_flag),
                    .core_state(core_state),

                    .decoded_nzp(decoded_nzp),
                    .decoded_immediate(decoded_immediate[7:0]), // branch target: PC-domain (8-bit)
                    .decoded_nzp_write_enable(decoded_nzp_write_enable),
                    .decoded_pc_mux(decoded_pc_mux),

                    .alu_out(active_alu_out[i][7:0]), // pc only reads N/Z/P in [2:0]
                    .branch_taken(all_branch_votes[w][i]),

                    .current_pc(pc_bus[w][i]),
                    .next_pc(next_pc_bus[w][i])
                );

                assign pc_bus[w][i] = next_pc_bus[w][i];
            end
        end
    endgenerate

endmodule