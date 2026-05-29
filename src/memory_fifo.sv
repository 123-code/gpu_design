`default_nettype none
`timescale 1ns/1ns

module memory_fifo #(
    parameter DEPTH = 4,      // How many requests can wait in line?
    parameter DATA_WIDTH = 8  // The size of the memory address (8 bits)
) (
    input wire clk,
    input wire reset,

    // ==========================================
    // THE CORE INTERFACE (The Chef)
    // ==========================================
    input wire write_enable,                // Core: "I have a request!"
    input wire [DATA_WIDTH-1:0] write_data, // Core: "Here is the address."
    output wire is_full,                    // FIFO: "Stop, the queue is full!"

    // ==========================================
    // THE ARBITER INTERFACE (The Customer)
    // ==========================================
    input wire read_enable,                 // Arbiter: "I am ready for the next request!"
    output reg [DATA_WIDTH-1:0] read_data,  // FIFO: "Here is the address."
    output wire is_empty                    // FIFO: "Nobody is waiting."
);

    // ==========================================
    // COMPONENT 1: The Memory Bank (The Belt)
    // ==========================================
    // An array of 4 physical 8-bit registers
    reg [DATA_WIDTH-1:0] buffer [0:DEPTH-1];

    // ==========================================
    // COMPONENT 2: The Pointers (The Sticky Notes)
    // ==========================================
    // 2-bit registers (which can hold 00, 01, 10, 11) to track indexes 0 to 3
    reg [1:0] write_ptr;
    reg [1:0] read_ptr;

    // ==========================================
    // COMPONENT 3: The Status Flags (Combinational Logic)
    // ==========================================
    // Empty: Pointers are at the exact same spot
    assign is_empty = (write_ptr == read_ptr);
    
    // Full: If we add 1 to the write_ptr, does it hit the read_ptr?
    // (We use % DEPTH to make it wrap from 3 back to 0)
    assign is_full = ((write_ptr + 1) % DEPTH == read_ptr);

    // The Output Highway: Always show the Arbiter whatever is at the read_ptr
    always @(*) begin
        read_data = buffer[read_ptr];
    end

    // ==========================================
    // THE CLOCK LOGIC (Moving the pointers)
    // ==========================================
    always @(posedge clk) begin
        if (reset) begin
            write_ptr <= 0;
            read_ptr <= 0;
        end else begin

            // PUSH: If Core wants to write, AND we aren't full...
            if (write_enable && !is_full) begin
                buffer[write_ptr] <= write_data;      // Put data in the slot
                write_ptr <= (write_ptr + 1) % DEPTH; // Move pointer to next slot
            end

            // POP: If Arbiter is ready to read, AND we aren't empty...
            if (read_enable && !is_empty) begin
                // (The data is already on the read_data wire)
                read_ptr <= (read_ptr + 1) % DEPTH;   // Move pointer to next slot
            end

        end
    end
endmodule