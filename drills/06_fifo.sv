// DRILL 06 — FIFO, depth 4 (~30 lines, the boss level)
//
// Synchronous FIFO, 8-bit wide, 4 deep, first-word fall-through:
//   - `rdata` ALWAYS shows the oldest stored element (combinational)
//   - wr_en=1 on a clock edge pushes wdata (ignored when full)
//   - rd_en=1 on a clock edge pops the oldest (ignored when empty)
//   - simultaneous push+pop is legal when neither ignoring rule applies
//   - full / empty flags; rst (sync, active high) empties the FIFO
//
// The shape: a small memory array, a write pointer, a read pointer, and a
// count. full = (count==4), empty = (count==0). Every queue between two
// clock domains or two pipeline stages in every chip ever is this + frills.
//
// Run:  make drill D=06_fifo

module fifo (
    input  logic       clk,
    input  logic       rst,
    input  logic       wr_en,
    input  logic [7:0] wdata,
    input  logic       rd_en,
    output logic [7:0] rdata,
    output logic       full,
    output logic       empty
);

    // TODO: logic [7:0] mem [4]; write ptr, read ptr, count.
    // Think about count when pushing and popping in the same cycle.

endmodule
