`default_nettype none
`timescale 1ns/1ns

// Main data memory the GPU threads read from, and the DMA writes into.
// Simple dual-port BRAM: one write port (driven by the DMA while loading),
// one synchronous read port (driven by a thread's LSU). Gowin infers this as
// a semi-dual-port BSRAM. 1-cycle read latency.
module main_memory #(
    parameter ADDR_BITS     = 13,            // 4096 bytes: image + conv/FC weights +
                                         // GPU-computed conv/pool/score scratch.
                                         // Maps to ~2-4 BSRAM blocks (of 46).
    parameter DEPTH     = (1 << ADDR_BITS)
) (
    input  wire                 clk,

    // ---- write port (DMA) ----
    input  wire                 we,
    input  wire [ADDR_BITS-1:0] waddr,
    input  wire [7:0]           wdata,

    // ---- read port (GPU) ----
    input  wire [ADDR_BITS-1:0] raddr,
    output reg  [7:0]           rdata
);
    reg [7:0] mem [0:DEPTH-1];

    // Bake the FC interleaved buffer at synthesis: weights in the odd slots, the
    // even (feature) slots zeroed -- the GPU's scatter pass fills them after pool.
    // 3380 entries land at FC_BUF_BASE. (The image and scratch regions are filled
    // at runtime by the DMA and the GPU's write port.)
`ifndef FC_BUF_HEX
    `define FC_BUF_HEX "/Users/joseignacio/tiny-gpu-fpga/software/mnist_data/fc_buf_init.hex"
`endif
    parameter FC_BUF_BASE = 2048;
    initial $readmemh(`FC_BUF_HEX, mem, FC_BUF_BASE, FC_BUF_BASE + 3380 - 1);

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;     // DMA / GPU store
        rdata <= mem[raddr];             // synchronous read (1-cycle latency)
    end
endmodule
