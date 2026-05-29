`default_nettype none
`timescale 1ns/1ns

module pc #(
    parameter DATA_MEM_DATA_BITS = 8,
    parameter PROGRAM_MEM_ADDR_BITS = 8
) (
    // ==========================================
    // SYSTEM PINS (Power & State)
    // ==========================================
    input wire clk,              // The metronome that triggers the memory vault to save [cite: 318]
    input wire reset,            // Flushes the vault to 0 [cite: 318]
    input wire enable,           // Is this specific thread active right now? [cite: 318]

    input wire [2:0] core_state,  // The current step in the execution loop [cite: 318]

    // ==========================================
    // CONTROL PINS (From the Decoder)
    // ==========================================
    input wire [2:0] decoded_nzp,              // The condition we are checking (e.g., '001' for Negative) [cite: 319]
    input wire [DATA_MEM_DATA_BITS-1:0] decoded_immediate, // THE JUMP WIRE (Target Address) [cite: 319]
    input wire decoded_nzp_write_enable,       // Switch: "Open the vault and save the ALU flags!" [cite: 319]
    input wire decoded_pc_mux,                 // THE MUX SWITCH: '0' = Adder, '1' = Jump Wire [cite: 319]

    // ==========================================
    // DATA PINS (Inputs & Outputs)
    // ==========================================
    input wire [DATA_MEM_DATA_BITS-1:0] alu_out,   // Cable from ALU (Bottom 3 bits are N, Z, P) [cite: 319]
    
    input wire [PROGRAM_MEM_ADDR_BITS-1:0] current_pc, // The line we are currently on [cite: 319]
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] next_pc    // The line we are going to [cite: 319]
);

    // ==========================================
    // COMPONENT 1: THE MEMORY VAULT 
    // ==========================================
    // A tiny 3-bit physical memory cell to hold the Negative, Zero, and Positive flags [cite: 320]
    reg [2:0] nzp;

    // The 'always' block creates the physical Flip-Flops. 
    // Nothing inside this block happens until the 'clk' voltage spikes from 0V to 3.3V (posedge). [cite: 320]
    always @(posedge clk) begin
        
        if (reset) begin
            nzp <= 3'b0;      // Empty the flag vault [cite: 320]
            next_pc <= 0;     // Point the finger back to line 0 [cite: 321]
            
        end else if (enable) begin
            
            // ==========================================
            // COMPONENTS 2, 3 & 4: THE ADDER, TARGET, & MUX
            // ==========================================
            // When the Scheduler reaches State 5 (EXECUTE) [cite: 321]
            if (core_state == 3'b101) begin 
                
                // MUX CHECK: Did the Decoder flip the switch to request a Jump? [cite: 321]
                if (decoded_pc_mux == 1) begin 
                    
                    // THE BRANCH LOGIC GATE: 
                    // Bitwise AND (&). Check if the vault's saved flag matches the requested flag [cite: 321]
                    if (((nzp & decoded_nzp) != 3'b0)) begin 
                        
                        // VALVE A OPENS: Condition met! 
                        // Route the Jump Wire through the MUX and into the output [cite: 322]
                        next_pc <= decoded_immediate; 
                        
                    end else begin 
                        
                        // VALVE B OPENS: Condition failed. 
                        // Route the +1 Adder through the MUX instead [cite: 322, 323]
                        next_pc <= current_pc + 1;
                    end
                    
                end else begin 
                    
                    // VALVE B OPENS: Standard instruction (Not a branch). 
                    // Route the +1 Adder through the MUX [cite: 324]
                    next_pc <= current_pc + 1;
                end
            end   

            // ==========================================
            // UPDATING THE VAULT
            // ==========================================
            // When the Scheduler reaches State 6 (UPDATE) [cite: 325]
            if (core_state == 3'b110) begin 
                
                // If the Decoder tells us a CMP instruction just happened... [cite: 325]
                if (decoded_nzp_write_enable) begin
                    
                    // Open the vault and catch the voltages currently sitting on the ALU wires [cite: 325]
                    nzp[2] <= alu_out[2]; // Save the N flag [cite: 326]
                    nzp[1] <= alu_out[1]; // Save the Z flag [cite: 326]
                    nzp[0] <= alu_out[0]; // Save the P flag [cite: 327]
                end
            end      
        end
    end
endmodule