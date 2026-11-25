`default_nettype none
`timescale 1ns/1ns

module scheduler #(
    parameter THREADS_PER_BLOCK = 4,   // lanes per warp (the warp size)
    parameter WARPS_PER_CORE = 2,
    parameter BLOCK_DIM = THREADS_PER_BLOCK  // launch size: how many threads this block runs
) (
    input wire clk,//clock inputv
    input wire reset,//reset signal
    input wire start,//signal from the dispatcher to begin execution
    input wire decoded_ret,//comes from the instruction decoder,turns on on RET instruction, means the program must halt if this is high, we no longer fetch, we go to DONE
    // LSU states, flattened: thread (w,i) at [(w*THREADS_PER_BLOCK+i)*2 +: 2].
    // (Packed, not an unpacked 2-D port: iverilog 12 crashes elaborating
    // unpacked-array ports when a dimension is [0:0], i.e. WARPS_PER_CORE=1.)
    input wire [WARPS_PER_CORE*THREADS_PER_BLOCK*2-1:0] lsu_state_flat,
    input wire [WARPS_PER_CORE-1:0] warp_emit,  // thread 0 of warp w has a UART emit in flight

    // Divergence signals
    input wire decoded_sync,
    input wire decoded_bar,
    // Cluster barrier: a CBAR is a BAR that, in a cluster launch, also waits
    // until the peer core's block has reached it
    input wire decoded_cbar,
    input wire cluster_mode,
    input wire peer_arrived,        // the peer core is parked at its CBAR
    output wire cbar_arrived,       // ... and so are we

    // Tensor core: an MMA/TCFG/TLD/TLDQ issued while the unit is busy parks
    // the warp (it yields) and re-executes once the unit is idle.
    input wire decoded_tc_op,
    input wire tc_busy,
    // Copy engine: TMA while a copy runs, or TMAWAIT, parks the same way
    input wire decoded_tma_op,
    input wire tma_busy,
    input wire decoded_pc_mux,
    input wire [7:0] decoded_immediate,
    input wire [THREADS_PER_BLOCK-1:0] branch_votes,

    // 1 if this instruction touches the LSU (LDR/STR/emit). Compute-only
    // instructions skip REQUEST/WAIT (they are pass-through for them).
    input wire decoded_mem_op,
    // The executing instruction's register write (RAW hazard check in RUN)
    input wire decoded_reg_write_enable,
    input wire [3:0] decoded_rd_address,
    // Pipeline strobes (see RUN below)
    output wire dec_latch,         // decoder + operand latch for the next instruction
    output wire w_load,            // the executing instruction moves to W
    output reg  w_fast,            // W writes back in a RUN cycle (overlapped)

    // The raw instruction word (ROM output). DECODE classifies it before the
    // registered decoder has caught up, to pick EXECUTE or REQUEST.
    input wire [15:0] instruction,
    // The instruction memory address: the current warp's PC, except in
    // UPDATE, where it is already the NEXT warp's PC (fetch overlaps writeback)
    output wire [7:0] fetch_addr,

    // Warp State Outputs
    output reg current_warp, // Which warp is currently driving the pipeline?
    output wire [WARPS_PER_CORE*8-1:0] warp_pc_flat,                    // warp w's PC at [w*8 +: 8]
    output wire [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0] active_mask_flat, // warp w's mask at [w*TPB +: TPB]

    output reg [3:0] core_state,//register holding state
    output reg done
);
//instructions or states in which the scheduler finds itself
//starts at idle, waiting for a sognal to run, once the dispatcher loads the image , the shceduler transitions to fetch
    localparam IDLE = 4'b0000, SELECT_WARP = 4'b0001, FETCH = 4'b0010, DECODE = 4'b0011,
               REQUEST = 4'b0100, WAIT = 4'b0101, EXECUTE = 4'b0110,
               UPDATE = 4'b0111, DONE = 4'b1000, RUN = 4'b1001;

    // WARP_BARRIER: parked at a BAR until every live warp of the block arrives
    localparam WARP_READY = 2'b00, WARP_WAITING = 2'b01, WARP_DONE = 2'b10,
               WARP_BARRIER = 2'b11;

    reg [7:0] warp_pc [WARPS_PER_CORE-1:0];
    reg [THREADS_PER_BLOCK-1:0] active_mask [WARPS_PER_CORE-1:0]; // which threads are awake
    wire [1:0] lsu_state [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    genvar gw, gi;
    generate
        for (gw = 0; gw < WARPS_PER_CORE; gw = gw + 1) begin : flat_ports
            assign warp_pc_flat[gw*8 +: 8] = warp_pc[gw];
            assign active_mask_flat[gw*THREADS_PER_BLOCK +: THREADS_PER_BLOCK] = active_mask[gw];
            for (gi = 0; gi < THREADS_PER_BLOCK; gi = gi + 1) begin : flat_lsu
                assign lsu_state[gw][gi] = lsu_state_flat[(gw*THREADS_PER_BLOCK+gi)*2 +: 2];
            end
        end
    endgenerate
    reg [1:0] warp_status [WARPS_PER_CORE-1:0];
    reg [WARPS_PER_CORE-1:0] tc_parked;   // waiting for the tensor core
    reg [WARPS_PER_CORE-1:0] tma_parked;  // waiting for the copy engine
    reg bar_cluster;                       // the pending barrier is a CBAR

    // Every live warp is parked at the barrier (computed from the statuses)
    reg at_bar_c, bar_open_c;
    always @(*) begin
        at_bar_c = 1'b0; bar_open_c = 1'b1;
        for (integer b = 0; b < WARPS_PER_CORE; b = b + 1) begin
            if (warp_status[b] == WARP_BARRIER) at_bar_c = 1'b1;
            if (warp_status[b] == WARP_READY || warp_status[b] == WARP_WAITING) bar_open_c = 1'b0;
        end
    end
    assign cbar_arrived = at_bar_c && bar_open_c && bar_cluster && cluster_mode;

    // Divergence Stacks (Per Warp), SDEPTH reconvergence levels each.
    //
    // Stored as flat PACKED bit-vectors, not unpacked arrays, ON PURPOSE:
    // GowinSynthesis tries to infer any single-read-port unpacked array as block
    // RAM and SIGSEGVs building its address decoder, and this toolchain version
    // has no syn_ramstyle support to opt out. Packed vectors accessed with a
    // variable `+:` part-select synthesize as plain logic muxes, so they are
    // never RAM-inferred. Entry for warp w, level d lives at flat index w*SDEPTH+d.
    localparam SDEPTH = 4;                                            // levels per warp
    reg [WARPS_PER_CORE*SDEPTH*8-1:0]                 stack_pc;       // 8-bit PC per entry
    reg [WARPS_PER_CORE*SDEPTH*THREADS_PER_BLOCK-1:0] stack_mask;     // mask per entry
    reg [WARPS_PER_CORE*2-1:0]                        stack_ptr;      // 2-bit ptr per warp
    // Mask active just before a (single-level) divergence, restored when the
    // reconvergence stack empties so post-merge code runs on all those lanes.
    reg [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0]        base_mask;      // mask per warp

    // ------------------------------------------------------------------
    // Overlapped issue. In UPDATE (the current instruction's writeback) the
    // scheduler already picks the next warp and drives the instruction
    // memory with its PC, so the next cycle is that instruction's DECODE --
    // no SELECT_WARP or FETCH cycle in between. Same policy as SELECT_WARP:
    // the lowest-index ready warp, where the current warp counts as ready
    // unless this instruction retires it (RET) or parks it (BAR/CBAR).
    // ------------------------------------------------------------------
    reg       nx_found;
    reg       nx_warp;
    always @(*) begin
        nx_found = 1'b0;
        nx_warp  = 1'b0;
        for (integer n = WARPS_PER_CORE - 1; n >= 0; n = n - 1) begin
            if ((n == current_warp) ? !(decoded_ret || decoded_bar)
                                    : (warp_status[n] == WARP_READY)) begin
                nx_found = 1'b1;
                nx_warp  = n[0];
            end
        end
    end
    // Instruction memory address. In DECODE of a fast instruction, prefetch
    // the next one; in RUN, keep one instruction ahead of X (or hold D while
    // it waits out a hazard).
    reg [7:0] fetch_r;
    always @(*) begin
        if (core_state == UPDATE && nx_found)                    fetch_r = warp_pc[nx_warp];
        else if (core_state == DECODE && d_fast)                 fetch_r = warp_pc[current_warp] + 8'd1;
        else if (core_state == RUN && x_valid)                   fetch_r = warp_pc[current_warp] + (run_adv ? 8'd2 : 8'd1);
        else if (core_state == RUN)                              fetch_r = warp_pc[current_warp] + (run_adv ? 8'd1 : 8'd0);
        else                                                     fetch_r = warp_pc[current_warp];
    end
    assign fetch_addr = fetch_r;

    // DECODE routing from the raw word: loads/stores need REQUEST (the LSU
    // starts there) and WAIT; tensor-core and copy-engine instructions need
    // REQUEST for the busy-unit check. Everything else goes straight to
    // EXECUTE (its operands were read in DECODE).
    wire [3:0] op = instruction[15:12];
    wire needs_request = (op == 4'b0100) || (op == 4'b1011)                // LDR*, STR*
                      || (op == 4'b0110 && instruction[11:9] != 3'd0)      // MMA, TCFG, MMA2
                      || (op == 4'b0111 && instruction[8:6] != 3'd0)       // TLD, TLDQ
                      || (op == 4'b1001 && instruction[10])                // TMA, TMAG
                      || (op == 4'b1111 && instruction[2]);                // TMAWAIT

    // ------------------------------------------------------------------
    // RUN: pipelined issue for "fast" instructions (ALU, MOV family, CMP,
    // BRn). RUN executes one instruction (X) while the next one (D, at the
    // ROM output: it was prefetched at X's PC + 1) is decoded and has its
    // operands read, and the one before X writes back (W). One instruction
    // per cycle while nothing interferes:
    //   - D depends on X's result      -> one bubble (D reads it from the
    //                                      W-stage bypass a cycle later)
    //   - X redirects control (a taken or divergent branch), D is not a
    //     fast instruction, or a lower-index warp became ready
    //                                   -> X finishes through UPDATE, which
    //                                      fetches whatever runs next
    // Everything else (memory, tensor core, copy engine, RET/SYNC/BAR...)
    // takes the DECODE -> (REQUEST/WAIT) -> EXECUTE -> UPDATE path.
    // ------------------------------------------------------------------
    reg x_valid;                      // RUN: an instruction is in X this cycle
    function automatic is_fast(input [15:0] ins);
        case (ins[15:12])
            4'b0001, 4'b0101, 4'b1110, 4'b1010, 4'b1100, 4'b1101,   // ADD ADDI SUB MUL SHR SHL
            4'b0010, 4'b0011, 4'b1000: is_fast = 1'b1;              // MOV-family CMP BRn
            default: is_fast = 1'b0;
        endcase
    endfunction
    wire       d_fast  = is_fast(instruction);
    wire [3:0] d_op    = instruction[15:12];
    wire       d_lui   = (d_op == 4'b0010) && (instruction[8:6] == 3'b100);
    wire [2:0] d_rs    = d_lui ? instruction[11:9] : instruction[8:6];
    wire       d_rd_rs = d_lui || d_op == 4'b0001 || d_op == 4'b0101 || d_op == 4'b1110 ||
                         d_op == 4'b1010 || d_op == 4'b1100 || d_op == 4'b1101 || d_op == 4'b0011;
    wire       d_rd_rt = d_op == 4'b0001 || d_op == 4'b1110 || d_op == 4'b1010 ||
                         d_op == 4'b1100 || d_op == 4'b1101 || d_op == 4'b0011;
    wire       x_writes = x_valid && decoded_reg_write_enable;
    wire       hazard  = x_writes && ((d_rd_rs && d_rs == decoded_rd_address[2:0]) ||
                                      (d_rd_rt && instruction[2:0] == decoded_rd_address[2:0]));
    reg        lower_ready;           // a lower-index warp is ready: let the scheduler switch
    always @(*) begin
        lower_ready = 1'b0;
        for (integer lw = 0; lw < WARPS_PER_CORE; lw = lw + 1)
            if (lw < current_warp && warp_status[lw] == WARP_READY) lower_ready = 1'b1;
    end
    wire x_redirect;                  // X is a taken or divergent branch
    wire run_adv  = (core_state == RUN) && d_fast && !lower_ready && !hazard && !(x_valid && x_redirect);
    wire run_stall = (core_state == RUN) && x_valid && !x_redirect && d_fast && !lower_ready && hazard;
    assign dec_latch = (core_state == DECODE) || run_adv;
    assign w_load    = (core_state == EXECUTE) || (core_state == RUN && x_valid);

    wire [THREADS_PER_BLOCK-1:0] want_to_branch = branch_votes & active_mask[current_warp];
    wire [THREADS_PER_BLOCK-1:0] want_to_stay   = (~branch_votes) & active_mask[current_warp];
    assign x_redirect = decoded_pc_mux && (want_to_branch != 0);

    always @(posedge clk) begin //every time the clock ticks,the sceduler checks its state
        if (reset) begin//reset , core state goes to IDLE
            core_state <= IDLE;
            done <= 0;
            current_warp <= 0;
            x_valid <= 1'b0;
            w_fast <= 1'b0;
            tc_parked <= '0;
            tma_parked <= '0;
            bar_cluster <= 1'b0;
            for (integer w = 0; w < WARPS_PER_CORE; w = w + 1) begin
                warp_pc[w] <= 0;
                stack_ptr[w*2 +: 2] <= 2'b0;
                // Launch-bounds (NVIDIA-style): only spin up the warps the
                // block actually needs. A warp whose first lane is past
                // BLOCK_DIM starts DONE so it never runs; a partially-full
                // warp predicates off its out-of-range lanes.
                if (w * THREADS_PER_BLOCK < BLOCK_DIM)
                    warp_status[w] <= WARP_READY;
                else
                    warp_status[w] <= WARP_DONE;
                for (integer i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin
                    if (w * THREADS_PER_BLOCK + i < BLOCK_DIM) begin
                        active_mask[w][i] <= 1'b1;
                        base_mask[w*THREADS_PER_BLOCK + i] <= 1'b1;
                    end else begin
                        active_mask[w][i] <= 1'b0;
                        base_mask[w*THREADS_PER_BLOCK + i] <= 1'b0;
                    end
                end
            end
        end else begin
            // 1. Monitor LSU for WAITING warps to wake them up
            reg [WARPS_PER_CORE-1:0] warp_is_waiting;
            reg [WARPS_PER_CORE-1:0] warp_issuing;   // any thread in LSU state 01 (just issued)
            for (integer w = 0; w < WARPS_PER_CORE; w = w + 1) begin
                warp_is_waiting[w] = 0;
                warp_issuing[w]    = 0;
                for (integer i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin
                    if (lsu_state[w][i] == 2'b01 || lsu_state[w][i] == 2'b10) begin
                        warp_is_waiting[w] = 1;
                    end
                    if (lsu_state[w][i] == 2'b01) warp_issuing[w] = 1;
                end

                // Wake up if it was waiting and LSU is done (and, if it is
                // parked on the tensor core, the unit is idle)
                if (warp_status[w] == WARP_WAITING && !warp_is_waiting[w]
                        && !(tc_parked[w] && tc_busy) && !(tma_parked[w] && tma_busy)) begin
                    warp_status[w] <= WARP_READY;
                    tc_parked[w]   <= 1'b0;
                    tma_parked[w]  <= 1'b0;
                end
            end

            // 2. Main FSM Pipeline
            case (core_state)//acts as a switchboard, checking the state of core_state register
            IDLE: begin//once the start signal comes in from dispatcher, we move on to FETCH
                if (start) core_state <= SELECT_WARP;
            end
            SELECT_WARP: begin
                // Lowest-index READY warp wins (loop form so it works for any
                // WARPS_PER_CORE, including 1). If none are READY and every warp
                // is DONE, the block is finished.
                reg        sw_found;
                reg        sw_all_done;
                reg        sw_at_bar;    // some warp is parked at a BAR
                reg        sw_bar_open;  // ... and every live warp is
                integer    sw;
                sw_found    = 1'b0;
                sw_all_done = 1'b1;
                sw_at_bar   = 1'b0;
                sw_bar_open = 1'b1;
                for (sw = 0; sw < WARPS_PER_CORE; sw = sw + 1) begin
                    if (!sw_found && warp_status[sw] == WARP_READY) begin
                        current_warp <= sw[0];   // 1-bit (WARPS_PER_CORE <= 2)
                        sw_found = 1'b1;
                    end
                    if (warp_status[sw] != WARP_DONE) sw_all_done = 1'b0;
                    if (warp_status[sw] == WARP_BARRIER) sw_at_bar = 1'b1;
                    if (warp_status[sw] == WARP_READY || warp_status[sw] == WARP_WAITING)
                        sw_bar_open = 1'b0;
                end
                if (sw_found)            core_state <= FETCH;
                else if (sw_all_done)    core_state <= DONE;
                else if (sw_at_bar && sw_bar_open
                         && (!(bar_cluster && cluster_mode) || peer_arrived)) begin
                    // Barrier complete: every warp that has not exited is
                    // parked at it (and, for a CBAR in a cluster launch, the
                    // peer block is too -- both cores see the other's arrival
                    // on the same edge and release together). Release them
                    // all; pick one next cycle.
                    for (sw = 0; sw < WARPS_PER_CORE; sw = sw + 1)
                        if (warp_status[sw] == WARP_BARRIER) warp_status[sw] <= WARP_READY;
                    bar_cluster <= 1'b0;
                end
            end
            FETCH: begin //fetching the next instruction
                core_state <= DECODE;
            end
            DECODE: begin
                // The register file latches rs/rt THIS cycle, straight from
                // the instruction word, so a compute instruction can execute
                // next cycle. Fast instructions enter the pipelined RUN state
                // (the next instruction is being prefetched now); memory /
                // tensor-core / copy-engine ops still go through REQUEST.
                if (d_fast) begin
                    core_state <= RUN;
                    x_valid    <= 1'b1;
                end else
                    core_state <= needs_request ? REQUEST : EXECUTE;
            end
            REQUEST: begin
                // For compute-only instructions WAIT is pure pass-through (the LSU
                // is idle), and rs/rt latched this cycle are valid next cycle, so
                // jump straight to EXECUTE: 7 cycles -> 6 (~1.17x). Memory ops
                // (LDR/STR/emit) still need WAIT for the LSU handshake.
                if (decoded_tc_op && tc_busy) begin
                    // Tensor core busy (an earlier async MMA): park and retry.
                    // The PC has not moved, so the warp re-fetches this
                    // instruction when it wakes.
                    warp_status[current_warp] <= WARP_WAITING;
                    tc_parked[current_warp]   <= 1'b1;
                    core_state <= SELECT_WARP;
                end else if (decoded_tma_op && tma_busy) begin
                    // Copy engine busy: TMA waits for the slot, TMAWAIT for
                    // the copy to land. Park; re-execute when it is idle.
                    warp_status[current_warp] <= WARP_WAITING;
                    tma_parked[current_warp]  <= 1'b1;
                    core_state <= SELECT_WARP;
                end else
                    core_state <= decoded_mem_op ? WAIT : EXECUTE;
            end
            WAIT: begin //checking if the threads are busy, checks if threads are reading, writing to RAM
                if (warp_emit[current_warp]) begin
                    // UART emit in flight: STALL on this warp (do not yield). A
                    // UART write has no latency to hide, and yielding would let
                    // the other warp interleave its framed output. Stay until the
                    // byte is acked (emit clears -> warp_emit drops).
                    core_state <= WAIT;
                end else if (warp_issuing[current_warp]) begin
                    // LSU just issued (state 01); wait one cycle so we can tell a
                    // memory read (yield) from an emit (stall) next cycle.
                    core_state <= WAIT;
                end else if (warp_is_waiting[current_warp]) begin
                    // Memory read in flight: park this warp and hide the latency.
                    warp_status[current_warp] <= WARP_WAITING;
                    core_state <= SELECT_WARP;
                end else begin
                    // No memory needed, math can execute.
                    core_state <= EXECUTE;
                end
            end
            EXECUTE, RUN: begin//performs operations, moves to update, operatins must be done in a single clock cycle
                reg [1:0]  sp;          // this warp's current stack pointer
                integer    e_pop, e_push; // flat stack entry index (w*SDEPTH + level)
                w_fast <= 1'b0;
                if (core_state == EXECUTE) core_state <= UPDATE;
                else begin
                    // RUN: what happens next (the X-stage effects below run
                    // only when x_valid)
                    if (x_valid) begin
                        if (run_adv) begin                 // D issues behind X
                            x_valid <= 1'b1; w_fast <= 1'b1; core_state <= RUN;
                        end else if (run_stall) begin      // bubble, then D
                            x_valid <= 1'b0; w_fast <= 1'b1; core_state <= RUN;
                        end else begin                     // X finishes alone
                            x_valid <= 1'b0; core_state <= UPDATE;
                        end
                    end else begin
                        if (run_adv) begin
                            x_valid <= 1'b1; core_state <= RUN;
                        end else begin
                            // D cannot issue here: refetch it the normal way
                            // (warp_pc already points at it)
                            core_state <= (lower_ready || d_fast) ? SELECT_WARP : DECODE;
                        end
                    end
                end
                if (core_state == EXECUTE || x_valid) begin
                sp = stack_ptr[current_warp*2 +: 2];
                if (decoded_sync) begin
                    if (sp > 0) begin
                        e_pop = current_warp*SDEPTH + (sp - 1);
                        warp_pc[current_warp]     <= stack_pc[e_pop*8 +: 8];
                        active_mask[current_warp] <= stack_mask[e_pop*THREADS_PER_BLOCK +: THREADS_PER_BLOCK];
                        stack_ptr[current_warp*2 +: 2] <= sp - 1;
                    end else begin
                        // Stack empty: the divergent region is fully reconverged.
                        // Restore the pre-divergence mask so the common code that
                        // follows runs on ALL lanes that were active going in
                        // (otherwise only the last-popped lanes stay awake).
                        warp_pc[current_warp]     <= warp_pc[current_warp] + 1;
                        active_mask[current_warp] <= base_mask[current_warp*THREADS_PER_BLOCK +: THREADS_PER_BLOCK];
                    end
                end else if (decoded_pc_mux) begin
                    if (want_to_branch != 0 && want_to_stay != 0) begin
                        // Divergence! Remember the full mask (only at the outermost
                        // divergence) so the matching reconverging SYNC can restore
                        // it, then push the 'stay' lanes and run the branch lanes.
                        if (sp == 0)
                            base_mask[current_warp*THREADS_PER_BLOCK +: THREADS_PER_BLOCK] <= active_mask[current_warp];
                        e_push = current_warp*SDEPTH + sp;
                        stack_pc[e_push*8 +: 8] <= warp_pc[current_warp] + 1;
                        stack_mask[e_push*THREADS_PER_BLOCK +: THREADS_PER_BLOCK] <= want_to_stay;
                        stack_ptr[current_warp*2 +: 2] <= sp + 1;

                        warp_pc[current_warp] <= decoded_immediate;
                        active_mask[current_warp] <= want_to_branch;
                    end else if (want_to_branch != 0) begin
                        warp_pc[current_warp] <= decoded_immediate;
                    end else begin
                        warp_pc[current_warp] <= warp_pc[current_warp] + 1;
                    end
                end else begin
                    warp_pc[current_warp] <= warp_pc[current_warp] + 1;
                end
                end
            end
            UPDATE: begin
                w_fast <= 1'b0; // depending on decoded_ret, if high, we're done, if low, we fetch another instrcution
                if (decoded_ret) begin
                    warp_status[current_warp] <= WARP_DONE;
                end else if (decoded_bar) begin
                    // Park at the barrier (PC already points past BAR)
                    warp_status[current_warp] <= WARP_BARRIER;
                    if (decoded_cbar) bar_cluster <= 1'b1;
                end
                // The next warp's instruction is being fetched right now
                // (fetch_addr); go straight to its DECODE. If no warp is
                // ready, fall back to SELECT_WARP (barrier release, done
                // detection, waiting for memory).
                if (nx_found) begin
                    current_warp <= nx_warp;
                    core_state   <= DECODE;
                end else
                    core_state   <= SELECT_WARP;
            end
            DONE: begin
            end
            endcase
            done <= (core_state == DONE);
        end
    end
endmodule
//q. how are we handling clock cycles here, if the threads run EXECUTE for exactly one cycle, ho does the MAC array do this?