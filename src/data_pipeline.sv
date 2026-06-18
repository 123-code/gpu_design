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
    parameter IMG_BYTES     = 784,        // bytes per image: the first image goes
                                          // to core 0's memory copy, the second
                                          // to core 1's
    parameter CLK_FREQ      = 27000000,
    parameter BAUD_RATE     = 115200
) (
    input  wire                 clk,
    input  wire                 reset,

    input  wire                 uart_rx_in,   // serial line from the host

    input  wire                 gpu_done,     // GPU finished the previous payload
    output wire                 gpu_start,    // 1-cycle "payload ready, go"
    output wire                 loading,      // high while the DMA owns memory

    // Instruction memory write ports (from DMA)
    output wire                 instr_we,
    output wire [7:0]           instr_waddr,
    output wire [15:0]          instr_wdata,

    // Core 0's read/write ports into its memory copy
    input  wire [ADDR_BITS-1:0] mem_raddr,
    output wire [7:0]           mem_rdata,

    // GPU write port (active while running); muxed against the DMA writer below
    input  wire                 gpu_we,
    input  wire [ADDR_BITS-1:0] gpu_waddr,
    input  wire [7:0]           gpu_wdata,

    // Core 1's read/write ports into its own memory copy. Replicating the
    // BRAM is how core 1 gets a private read port (the core<->memory read
    // path has no handshake, so the port can't be time-shared); the DMA
    // broadcast keeps both copies loaded with the same payload.
    input  wire [ADDR_BITS-1:0] mem_raddr_1,
    output wire [7:0]           mem_rdata_1,
    input  wire                 gpu_we_1,
    input  wire [ADDR_BITS-1:0] gpu_waddr_1,
    input  wire [7:0]           gpu_wdata_1
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
        .ADDR_BITS(ADDR_BITS)
    ) u_dma (
        .clk(clk), .reset(reset),
        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .gpu_done(gpu_done), .gpu_start(gpu_start),
        .mem_we(dma_we), .mem_waddr(dma_waddr), .mem_wdata(dma_wdata),
        .instr_we(instr_we), .instr_waddr(instr_waddr), .instr_wdata(instr_wdata),
        .loading(loading)
    );

    // ---- Write-port owner: the DMA while loading, the GPU while running ----
    // The DMA stream is split by address: payload bytes [0, IMG_BYTES) land in
    // core 0's copy, [IMG_BYTES, 2*IMG_BYTES) land in core 1's copy at offset 0.
    wire dma_to_1 = dma_waddr >= IMG_BYTES;

    wire                 mem_we    = loading ? (dma_we && !dma_to_1) : gpu_we;
    wire [ADDR_BITS-1:0] mem_waddr = loading ? dma_waddr             : gpu_waddr;
    wire [7:0]           mem_wdata = loading ? dma_wdata             : gpu_wdata;

    wire                 mem_we_1    = loading ? (dma_we && dma_to_1)      : gpu_we_1;
    wire [ADDR_BITS-1:0] mem_waddr_1 = loading ? (dma_waddr - IMG_BYTES)   : gpu_waddr_1;
    wire [7:0]           mem_wdata_1 = loading ? dma_wdata                 : gpu_wdata_1;

    // ---- Main data memory, one copy per core ----
    main_memory #(
        .ADDR_BITS(ADDR_BITS)
    ) u_mem (
        .clk(clk),
        .we(mem_we), .waddr(mem_waddr), .wdata(mem_wdata),
        .raddr(mem_raddr), .rdata(mem_rdata)
    );

    main_memory #(
        .ADDR_BITS(ADDR_BITS)
    ) u_mem_1 (
        .clk(clk),
        .we(mem_we_1), .waddr(mem_waddr_1), .wdata(mem_wdata_1),
        .raddr(mem_raddr_1), .rdata(mem_rdata_1)
    );

endmodule
