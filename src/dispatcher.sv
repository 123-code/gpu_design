`default_nettype none
`timescale 1ns/1ns

module dispatcher #(
    parameter TOTAL_BLOCKS = 4
) (
    input wire clk,
    input wire reset,
    input wire enable,
    
    input wire core_0_done, // Incoming ping from Core 0
    input wire core_1_done, // Incoming ping from Core 1

    output reg core_0_start,    // Outgoing ping to Core 0
    output reg [7:0] core_0_id, // Outgoing Work Order to Core 0
    
    output reg core_1_start,    // Outgoing ping to Core 1
    output reg [7:0] core_1_id  // Outgoing Work Order to Core 1
);

    // ==========================================
    // COMPONENT 1: The Block Counter
    // ==========================================
    reg [7:0] next_block_id;

    // ==========================================
    // COMPONENT 2: The Status Vaults
    // ==========================================
    reg core_0_busy;
    reg core_1_busy;

    always @(posedge clk) begin
        if (reset) begin
            next_block_id <= 0;
            core_0_busy <= 0;
            core_1_busy <= 0;
            core_0_start <= 0;
            core_1_start <= 0;
        end else if (enable) begin
            // Turn off the start pulses by default
            core_0_start <= 0;
            core_1_start <= 0;

            // Unlock Component 2 (Status Vaults) if the Cores ping us
            if (core_0_done) core_0_busy <= 0;
            if (core_1_done) core_1_busy <= 0;

            // ==========================================
            // COMPONENT 3: The Routing Logic
            // ==========================================
            
            // Check Component 2: Is Core 0's vault unlocked (0)?
            if (!core_0_busy && !core_0_done) begin
                core_0_start <= 1;
                core_0_id <= next_block_id;
                core_0_busy <= 1;
                next_block_id <= next_block_id + 1;
            end else if (!core_1_busy && !core_1_done) begin
                core_1_start <= 1;
                core_1_id <= next_block_id;
                core_1_busy <= 1;
                next_block_id <= next_block_id + 1;
            end
        end
    end
endmodule