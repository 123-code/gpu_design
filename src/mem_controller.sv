`default_nettype none
`timescale 1ns/1ns

module memory_arbiter (
    input wire clk,
    input wire reset,

    // ==========================================
    // COMPONENT 1: The Input Requests (From Cores)
    // ==========================================
    // "I need memory!" flags
    input wire core_0_valid, 
    input wire core_1_valid,
    // The addresses they want to read
    input wire [7:0] core_0_address,
    input wire [7:0] core_1_address,

    // ==========================================
    // COMPONENT 3: The Outputs Back to Cores
    // ==========================================
    // "RAM is ready, grab your data!" flags
    output reg core_0_ready,
    output reg core_1_ready,

    // ==========================================
    // EXTERNAL RAM PINS (The Single Lane)
    // ==========================================
    output reg ram_valid,
    output reg [7:0] ram_address,
    input wire ram_ready,          // RAM saying "I have the data!"
    input wire [7:0] ram_data_out  // The actual data payload from RAM
);

    // ==========================================
    // COMPONENT 2: The Arbiter State Vault
    // ==========================================
    // Who holds the traffic cop's baton right now?
    // 0 = Nobody, 1 = Core 0 is crossing, 2 = Core 1 is crossing
    reg [1:0] active_core; 

    always @(posedge clk) begin
        if (reset) begin
            active_core <= 0;
            ram_valid <= 0;
            core_0_ready <= 0;
            core_1_ready <= 0;
        end else begin
            
            // Turn off the ready pulses by default
            core_0_ready <= 0;
            core_1_ready <= 0;

            // ----------------------------------------------------
            // STATE 0: IDLE (Waiting for a request)
            // ----------------------------------------------------
            if (active_core == 0) begin
                
                // If Core 0 asks first, give it the baton
                if (core_0_valid) begin
                    active_core <= 1;
                    ram_valid <= 1;                 // Ring the RAM
                    ram_address <= core_0_address;  // Route Core 0's address
                
                // If Core 1 asks, give it the baton
                end else if (core_1_valid) begin
                    active_core <= 2;
                    ram_valid <= 1;                 // Ring the RAM
                    ram_address <= core_1_address;  // Route Core 1's address
                end

            // ----------------------------------------------------
            // STATE 1: SERVING CORE 0
            // ----------------------------------------------------
            end else if (active_core == 1) begin
                // Stand still until RAM says it is finished
                if (ram_ready) begin
                    core_0_ready <= 1; // Tell Core 0 to catch the data payload!
                    ram_valid <= 0;    // Hang up the phone with RAM
                    active_core <= 0;  // Drop the baton (Go back to IDLE)
                end

            // ----------------------------------------------------
            // STATE 2: SERVING CORE 1
            // ----------------------------------------------------
            end else if (active_core == 2) begin
                // Stand still until RAM says it is finished
                if (ram_ready) begin
                    core_1_ready <= 1; // Tell Core 1 to catch the data payload!
                    ram_valid <= 0;    
                    active_core <= 0;  
                end
            end
        end
    end
endmodule