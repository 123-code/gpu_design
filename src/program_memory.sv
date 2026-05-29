`default_nettype none
`timescale 1ns/1ns

module program_memory #(
    parameter DEPTH = 256,       // Max lines of code
    parameter WIDTH = 16         // 16-bit instructions
) (
    input wire clk,
    input wire [7:0] address,    // From the Fetcher/PC
    output reg [WIDTH-1:0] instruction
);

    // Physically allocate a block of BRAM on the FPGA
    reg [WIDTH-1:0] rom_array [0:DEPTH-1];

    // Burn the machine code into the silicon when flashing.
    // NOTE: absolute path on purpose — Gowin synthesis runs from impl/gwsynthesis/,
    // so a relative path silently fails to load (ROM fills with 0s and the whole
    // design constant-folds away). Update this if you move the repo.
    initial begin
        // The Rust assembler writes this file (software/src/main.rs).
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/kernel.hex", rom_array);
    end

    // Clock-synchronous read (Standard BRAM behavior)
    always @(posedge clk) begin
        instruction <= rom_array[address];
    end

endmodule