`default_nettype none
`timescale 1ns/1ns

// Host-to-Device data pipeline: UART receiver -> DMA -> main memory.
//
//   uart_rx  : deserializes bytes off the wire (rx_byte + rx_valid pulse)
//   dma      : writes each byte sequentially into SRAM, triggers the GPU
//   main_mem : dual-port BRAM; DMA owns the write port, GPU owns the read port
//
// The read port (mem_raddr/mem_rdata) is exposed so the GPU's LSU (later) — and
// the testbench (now) — can read back the loaded payload.
module data_pipeline #(
    parameter ADDR_BITS     = 13,         // 4096-byte main memory (2nd BRAM mapped)
    parameter PAYLOAD_BYTES = 793,        // overridden by top for the active kernel
    parameter CLK_FREQ      = 27000000,
    parameter BAUD_RATE     = 115200
) (
    input  wire                 clk,
    input  wire                 reset,

    input  wire                 uart_rx_in,   // serial line from the host

    input  wire                 gpu_done,     // GPU finished the previous payload
    output wire                 gpu_start,    // 1-cycle "payload ready, go"
    output wire                 loading,      // high while the DMA owns memory

    // GPU read port into main memory
    input  wire [ADDR_BITS-1:0] mem_raddr,
    output wire [7:0]           mem_rdata,

    // GPU write port (active while running); muxed against the DMA writer below
    input  wire                 gpu_we,
    input  wire [ADDR_BITS-1:0] gpu_waddr,
    input  wire [7:0]           gpu_wdata
);

    // ---- UART receiver ----
    wire [7:0] rx_byte;
    wire       rx_valid;
    uart_rx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) u_rx (
        .clk(clk), .reset(reset),
        .rx_in(uart_rx_in),
        .rx_byte(rx_byte), .rx_valid(rx_valid)
    );

    // ---- DMA controller drives the SRAM write port ----
    wire                 dma_we;
    wire [ADDR_BITS-1:0] dma_waddr;
    wire [7:0]           dma_wdata;
    dma_controller #(
        .ADDR_BITS(ADDR_BITS),
        .PAYLOAD_BYTES(PAYLOAD_BYTES)
    ) u_dma (
        .clk(clk), .reset(reset),
        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .gpu_done(gpu_done), .gpu_start(gpu_start),
        .mem_we(dma_we), .mem_waddr(dma_waddr), .mem_wdata(dma_wdata),
        .loading(loading)
    );

    // ---- Write-port owner: the DMA while loading, the GPU while running ----
    wire                 mem_we    = loading ? dma_we    : gpu_we;
    wire [ADDR_BITS-1:0] mem_waddr = loading ? dma_waddr : gpu_waddr;
    wire [7:0]           mem_wdata = loading ? dma_wdata : gpu_wdata;

    // ---- Main data memory ----
    main_memory #(
        .ADDR_BITS(ADDR_BITS)
    ) u_mem (
        .clk(clk),
        .we(mem_we), .waddr(mem_waddr), .wdata(mem_wdata),
        .raddr(mem_raddr), .rdata(mem_rdata)
    );

endmodule
