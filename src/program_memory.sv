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
    input wire [5:0] operand_b   // -> R2 (addr 1)
);

    // Physically allocate a block of BRAM on the FPGA
    reg [WIDTH-1:0] rom_array [0:DEPTH-1];

    // Burn the machine code into the silicon when flashing.
    // NOTE: absolute path on purpose — Gowin synthesis runs from impl/gwsynthesis/,
    // so a relative path silently fails to load (ROM fills with 0s and the whole
    // design constant-folds away). Update this if you move the repo.
    // Override with e.g. iverilog -DKERNEL_HEX="\"...conv_kernel.hex\"" for tests.
`ifndef KERNEL_HEX
    `define KERNEL_HEX "/Users/joseignacio/tiny-gpu-fpga/software/kernel.hex"
`endif
    initial begin
        // The Rust assembler writes this file (software/src/main.rs).
        $readmemh(`KERNEL_HEX, rom_array);
    end

    // Clock-synchronous read (Standard BRAM behavior). Two operand-loading
    // instructions get their immediate field replaced with the live UART values.
    always @(posedge clk) begin
        case (address)
            8'd1:    instruction <= {rom_array[1][15:6], operand_b}; // MOV R2,#B
            8'd3:    instruction <= {rom_array[3][15:6], operand_a}; // MOV R4,#A
            default: instruction <= rom_array[address];
        endcase
    end

endmodule