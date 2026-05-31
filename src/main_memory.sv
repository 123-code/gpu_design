`default_nettype none
`timescale 1ns/1ns

// Main data memory the GPU threads read from, and the DMA writes into.
// Simple dual-port BRAM: one write port (driven by the DMA while loading),
// one synchronous read port (driven by a thread's LSU). Gowin infers this as
// a semi-dual-port BSRAM. 1-cycle read latency.
module main_memory #(
    parameter ADDR_BITS = 10,            // 1024 bytes (fits a 28x28 image + weights)
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

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;     // DMA store
        rdata <= mem[raddr];             // synchronous read (1-cycle latency)
    end
endmodule
