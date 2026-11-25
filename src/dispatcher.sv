`default_nettype none
`timescale 1ns/1ns

// Grid scheduler: hands the blocks of a launch to the cores as they free up.
//
// A launch is a grid of `grid_dim` blocks (blockIdx 0..grid_dim-1). Each core
// runs one block at a time. The moment a core finishes its block, the
// dispatcher resets that core (fresh registers, PCs, LSU bases, warp state;
// memory is untouched) and starts it on the next unissued block. This is what
// an SM does with a CTA queue: the number of blocks is a property of the
// launch, not of the hardware, and a core that finishes early picks up more
// work instead of idling.
//
//   grid_dim == 0 -> legacy launch: 2 blocks, one per core (what every kernel
//                    written before grid scheduling expects).
//
// Output order. Kernels talk to the host through one UART, so the bytes of
// different blocks must not interleave. `emit_block` is the lowest block that
// has not finished; only the core running it may emit (gpu.sv routes the UART
// to it). Others stall on their first emit until their turn. That keeps the
// reply in blockIdx order no matter which core ran what. To bound the
// bookkeeping, blocks are only issued up to WINDOW ahead of emit_block (a
// block that finished out of order waits in `fin` until everything before it
// has). With in-order issue the lowest unfinished block is always running, so
// this cannot deadlock.
//
// done is a level: it rises once every block of the grid has finished and
// stays high until the next run's reset (the DMA re-arms on its rising edge).
module dispatcher #(
    parameter WINDOW = 8                 // max blocks in flight past emit_block
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       enable,
    input  wire [7:0] grid_dim,          // blocks in this launch (0 = legacy 2)
    input  wire       cluster,           // cluster launch: blocks 2k/2k+1 run together

    input  wire       core_0_done,       // sticky level from core 0's scheduler
    input  wire       core_1_done,       // sticky level from core 1's scheduler

    output reg        core_0_reset,      // 1-cycle per-block reset to core 0
    output reg        core_0_start,      // 1-cycle start pulse (cycle after reset)
    output reg  [7:0] core_0_id,         // blockIdx handed to core 0
    output reg        core_1_reset,
    output reg        core_1_start,
    output reg  [7:0] core_1_id,

    output reg        core_0_busy,       // core holds an unfinished block
    output reg        core_1_busy,
    output reg  [7:0] emit_block,        // lowest unfinished block (UART owner)

    output wire       done               // every block of the grid finished
);
    wire [7:0] total = (grid_dim == 8'd0) ? 8'd2 : grid_dim;

    reg [7:0]        next_block;         // next blockIdx to hand out
    reg [WINDOW-1:0] fin;                // fin[k]: block emit_block+k finished
    reg [1:0]        pending_start;      // core reset this cycle, start next cycle

    // A core's done is sticky from its scheduler; it falls one cycle after we
    // reset the core. `retire` = done seen on a busy core (counted once: busy
    // drops the same cycle).
    wire retire_0 = core_0_busy && core_0_done && !pending_start[0];
    wire retire_1 = core_1_busy && core_1_done && !pending_start[1];

    // Window offsets of the blocks retiring this cycle
    wire [7:0] off_0 = core_0_id - emit_block;
    wire [7:0] off_1 = core_1_id - emit_block;

    // Finished-set after this cycle's retirements, before the in-order drain
    reg [WINDOW-1:0] fin_next;
    integer k;
    reg [7:0] drain;                     // how many leading finished blocks retire
    always @(*) begin
        fin_next = fin;
        if (retire_0) fin_next[off_0[$clog2(WINDOW)-1:0]] = 1'b1;
        if (retire_1) fin_next[off_1[$clog2(WINDOW)-1:0]] = 1'b1;
        drain = 8'd0;
        for (k = 0; k < WINDOW; k = k + 1)
            if (fin_next[k] && drain == k) drain = drain + 8'd1;
    end

    // Can a block be issued this cycle? (in the grid, and inside the window
    // measured from where emit_block will be after this cycle's drain)
    wire [7:0] emit_after = emit_block + drain;
    wire can_issue = (next_block < total) && (next_block - emit_after < WINDOW);

    always @(posedge clk) begin
        if (reset) begin
            next_block    <= 8'd0;
            emit_block    <= 8'd0;
            fin           <= '0;
            pending_start <= 2'b00;
            core_0_busy   <= 1'b0;  core_1_busy  <= 1'b0;
            core_0_reset  <= 1'b0;  core_1_reset <= 1'b0;
            core_0_start  <= 1'b0;  core_1_start <= 1'b0;
            core_0_id     <= 8'd0;  core_1_id    <= 8'd0;
        end else if (enable) begin
            core_0_reset <= 1'b0;  core_1_reset <= 1'b0;
            core_0_start <= pending_start[0];
            core_1_start <= pending_start[1];
            pending_start <= 2'b00;

            // In-order retirement
            fin        <= fin_next >> drain;
            emit_block <= emit_after;
            if (retire_0) core_0_busy <= 1'b0;
            if (retire_1) core_1_busy <= 1'b0;

            // Issue: at most one block per cycle, core 0 first. A core is free
            // when it is not busy (or is retiring right now).
            //
            // Cluster launch: blocks 2k and 2k+1 form a pair and must be
            // co-resident (they share shared memory and barriers), so they
            // are issued together -- 2k to core 0, 2k+1 to core 1 -- only
            // when both cores are free. The rank is blockIdx & 1.
            if (cluster) begin
                if (can_issue && (!core_0_busy || retire_0) && (!core_1_busy || retire_1)
                        && pending_start == 2'b00) begin
                    core_0_id        <= next_block;
                    core_0_busy      <= 1'b1;
                    core_0_reset     <= 1'b1;
                    pending_start[0] <= 1'b1;
                    if (next_block + 8'd1 < total) begin
                        core_1_id        <= next_block + 8'd1;
                        core_1_busy      <= 1'b1;
                        core_1_reset     <= 1'b1;
                        pending_start[1] <= 1'b1;
                        next_block       <= next_block + 8'd2;
                    end else
                        next_block       <= next_block + 8'd1;
                end
            end else if (can_issue && (!core_0_busy || retire_0) && !pending_start[0]) begin
                core_0_id        <= next_block;
                core_0_busy      <= 1'b1;
                core_0_reset     <= 1'b1;
                pending_start[0] <= 1'b1;
                next_block       <= next_block + 8'd1;
            end else if (can_issue && (!core_1_busy || retire_1) && !pending_start[1]) begin
                core_1_id        <= next_block;
                core_1_busy      <= 1'b1;
                core_1_reset     <= 1'b1;
                pending_start[1] <= 1'b1;
                next_block       <= next_block + 8'd1;
            end
        end
    end

    assign done = (emit_block == total) && !core_0_busy && !core_1_busy;

endmodule
