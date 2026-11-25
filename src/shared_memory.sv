`default_nettype none
`timescale 1ns/1ns

// Per-core shared memory (the SM's scratchpad, CUDA `__shared__`).
//
// 1 KB as 256 x 32-bit words. 32 bits wide so the tensor core can pull a
// whole K=4 int8 row (or 8 fp4 values) per read; threads see it through
// LDS/STS as 16-bit halfwords (byte address, bit 0 ignored), matching the
// register width. Writes carry byte enables, so a halfword store or a byte
// from the copy engine touches only its own lanes of the word.
//
// Simple dual port (one write, one synchronous read, 1-cycle latency): the
// shape Gowin BSRAM and yosys' synth_gowin map directly. The core muxes the
// requesters (thread LSUs, tensor core, copy engine) onto these two ports.
module shared_memory #(
    parameter WORDS = 256
) (
    input  wire                     clk,

    input  wire                     we,
    input  wire [$clog2(WORDS)-1:0] waddr,
    input  wire [31:0]              wdata,
    input  wire [3:0]               wbe,      // byte enables

    input  wire [$clog2(WORDS)-1:0] raddr,
    output reg  [31:0]              rdata
);
    reg [31:0] mem [0:WORDS-1];

    // Sim only: real BSRAM powers up to 0, iverilog to X
    integer i;
    initial for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'd0;

    always @(posedge clk) begin
        if (we) begin
            if (wbe[0]) mem[waddr][7:0]   <= wdata[7:0];
            if (wbe[1]) mem[waddr][15:8]  <= wdata[15:8];
            if (wbe[2]) mem[waddr][23:16] <= wdata[23:16];
            if (wbe[3]) mem[waddr][31:24] <= wdata[31:24];
        end
        rdata <= mem[raddr];
    end
endmodule
