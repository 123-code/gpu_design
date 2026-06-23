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
    input wire [1:0] lsu_state [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0],//signals from the lsu to indicate its state
    input wire [WARPS_PER_CORE-1:0] warp_emit,  // thread 0 of warp w has a UART emit in flight

    // Divergence signals
    input wire decoded_sync,
    input wire decoded_pc_mux,
    input wire [7:0] decoded_immediate,
    input wire [THREADS_PER_BLOCK-1:0] branch_votes,
    
    // Warp State Outputs
    output reg current_warp, // Which warp is currently driving the pipeline?
    output reg [7:0] warp_pc [WARPS_PER_CORE-1:0],
    output reg [THREADS_PER_BLOCK-1:0] active_mask [WARPS_PER_CORE-1:0], // register "remembers" which threads are currently awake

    output reg [3:0] core_state,//register holding state
    output reg done
);
//instructions or states in which the scheduler finds itself
//starts at idle, waiting for a sognal to run, once the dispatcher loads the image , the shceduler transitions to fetch
    localparam IDLE = 4'b0000, SELECT_WARP = 4'b0001, FETCH = 4'b0010, DECODE = 4'b0011, 
               REQUEST = 4'b0100, WAIT = 4'b0101, EXECUTE = 4'b0110, 
               UPDATE = 4'b0111, DONE = 4'b1000;

    localparam WARP_READY = 2'b00, WARP_WAITING = 2'b01, WARP_DONE = 2'b10;
    reg [1:0] warp_status [WARPS_PER_CORE-1:0];

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

    wire [THREADS_PER_BLOCK-1:0] want_to_branch = branch_votes & active_mask[current_warp];
    wire [THREADS_PER_BLOCK-1:0] want_to_stay   = (~branch_votes) & active_mask[current_warp];

    always @(posedge clk) begin //every time the clock ticks,the sceduler checks its state
        if (reset) begin//reset , core state goes to IDLE
            core_state <= IDLE;
            done <= 0;
            current_warp <= 0;
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
                
                // Wake up if it was waiting and LSU is done
                if (warp_status[w] == WARP_WAITING && !warp_is_waiting[w]) begin
                    warp_status[w] <= WARP_READY;
                end
            end

            // 2. Main FSM Pipeline
            case (core_state)//acts as a switchboard, checking the state of core_state register
            IDLE: begin//once the start signal comes in from dispatcher, we move on to FETCH
                if (start) core_state <= SELECT_WARP; 
            end
            SELECT_WARP: begin
                // Simple Round-Robin Warp Picker
                if (warp_status[0] == WARP_READY) begin
                    current_warp <= 0;
                    core_state <= FETCH;
                end else if (warp_status[1] == WARP_READY) begin
                    current_warp <= 1;
                    core_state <= FETCH;
                end else if (warp_status[0] == WARP_DONE && warp_status[1] == WARP_DONE) begin
                    core_state <= DONE;
                end
            end
            FETCH: begin //fetching the next instruction
                core_state <= DECODE;
            end
            DECODE: begin//tanslated the instruction
                core_state <= REQUEST; 
            end
            REQUEST: begin 
                core_state <= WAIT;    
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
            EXECUTE: begin//performs operations, moves to update, operatins must be done in a single clock cycle
                reg [1:0]  sp;          // this warp's current stack pointer
                integer    e_pop, e_push; // flat stack entry index (w*SDEPTH + level)
                core_state <= UPDATE;
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
            UPDATE: begin // depending on decoded_ret, if high, we're done, if low, we fetch another instrcution
                if (decoded_ret) begin 
                    warp_status[current_warp] <= WARP_DONE;
                    core_state <= SELECT_WARP;
                end else begin 
                    core_state <= SELECT_WARP; // Context switch every instruction!
                end
            end
            DONE: begin 
            end
            endcase
            done <= (core_state == DONE);
        end
    end
endmodule
//q. how are we handling clock cycles here, if the threads run EXECUTE for exactly one cycle, ho does the MAC array do this?