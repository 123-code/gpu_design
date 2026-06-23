`default_nettype none
`timescale 1ns/1ns

module program_memory #(
    parameter DEPTH = 256,       // Max lines of code
    parameter WIDTH = 16         // 16-bit instructions
) (
    input wire clk,
    input wire [7:0] address,    // From the Fetcher/PC
    output reg [WIDTH-1:0] instruction,

    // Runtime operands injected over UART. These overwrite the 6-bit immediate
    // fields of the two operand-loading MOV instructions in the kernel:
    //   addr 1: MOV R2,#B (loop count)  addr 3: MOV R4,#A (addend)
    input wire [5:0] operand_a,  // -> R4 (addr 3)
    input wire [5:0] operand_b,  // -> R2 (addr 1)
    
    // DMA write ports to load instructions dynamically
    input wire               we,
    input wire [7:0]         waddr,
    input wire [WIDTH-1:0]   wdata
);

    // Physically allocate a block of BRAM on the FPGA. (Inferred as block RAM by
    // yosys/synth_gowin in the open-source flow. NOTE: Gowin's proprietary
    // GowinSynthesis SIGSEGVs inferring this; we build with the OSS toolchain.)
    reg [WIDTH-1:0] rom_array [0:DEPTH-1];

    // Clock-synchronous read and write
    always @(posedge clk) begin
        if (we) begin
            rom_array[waddr] <= wdata;
        end
        instruction <= rom_array[address];
    end

endmodule