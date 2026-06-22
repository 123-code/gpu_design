`default_nettype none
`timescale 1ns/1ns

module registers #(
    // Hardware compilation variables. These set the read-only Thread IDs.
    parameter THREADS_PER_BLOCK = 4,
    parameter THREAD_ID = 0,
    parameter DATA_BITS = 8
) (
    // ==========================================
    // PART 1: SYSTEM PINS (Power and State)
    // ==========================================
    input wire clk,
    input wire reset,
    input wire enable, // Is this thread active? (1 = Yes, 0 = No)

    input wire [7:0] block_id,    // Passed down from the Dispatcher
    input wire [2:0] core_state,  // Passed down from the Scheduler
    input wire thread_active,                      // From Stage 1: Thread-level masking
    input wire warp_active,                        // NEW: Warp-level maskingwake?

    // ==========================================
    // PART 2: CONTROL PINS (Wires coming from the DECODER)
    // ==========================================
    input wire [3:0] decoded_rd_address,       // Destination slot (0 to 15)
    input wire [3:0] decoded_rs_address,       // Read slot 1
    input wire [3:0] decoded_rt_address,       // Read slot 2
    
    input wire decoded_reg_write_enable,       // Switch: "Save data now!"
    input wire [1:0] decoded_reg_input_mux,    // Switch: "Where is the data coming from?"
    input wire [DATA_BITS-1:0] decoded_immediate, // Raw constant number from instruction

    // SIMT identity read (TID/BID/BDIM): when high, write the identity register
    // picked by decoded_rs_address (1->R15, 2->R13, 3->R14) into rd.
    input wire decoded_id_read,

    // ==========================================
    // PART 3: DATA PINS IN (Wires bringing answers back)
    // ==========================================
    input wire [DATA_BITS-1:0] alu_out,        // The answer cable from the ALU
    input wire [DATA_BITS-1:0] lsu_out,        // The answer cable from External Memory

    // ==========================================
    // PART 4: DATA PINS OUT (Wires feeding the ALU/Memory)
    // ==========================================
    output reg [7:0] rs,
    output reg [7:0] rt,

    // Result from the shared 3x3 MAC unit (written back by the MAC instruction)
    input wire [DATA_BITS-1:0] mac_result,

    // Debug tap: continuously expose R3 (the kernel's accumulator) so the
    // top-level wrapper can show the result on the board LEDs.
    output wire [7:0] debug_reg3
);

    // Human-readable names for the Input Multiplexer (The routing switch)
    localparam ARITHMETIC = 2'b00,
               MEMORY     = 2'b01,
               CONSTANT   = 2'b10,
               MAC        = 2'b11;

    // ==========================================
    // PART 5: THE INTERNAL VAULT (The Memory Cells)
    // ==========================================
    // This creates an array of 16 slots, where each slot holds an 8-bit wire bundle
    reg [7:0] registers[15:0];

    // Debug tap (declared after the register array so the assign is legal)
    assign debug_reg3 = registers[3];

    // The Clocked Logic Machinery
    always @(posedge clk) begin
        if (reset) begin
            // On boot, drain all electricity (set to 0)
            rs <= 0;
            rt <= 0;
            
            // Empty the 13 free registers [cite: 333, 334, 335]
            registers[0] <= 8'b0; registers[1] <= 8'b0; registers[2] <= 8'b0;
            registers[3] <= 8'b0; registers[4] <= 8'b0; registers[5] <= 8'b0;
            registers[6] <= 8'b0; registers[7] <= 8'b0; registers[8] <= 8'b0;
            registers[9] <= 8'b0; registers[10] <= 8'b0; registers[11] <= 8'b0;
            registers[12] <= 8'b0;

            // Initialize the 3 hardware-coded SIMD identity registers [cite: 336, 337, 338]
            registers[13] <= 8'b0;              // %blockIdx (Updates later)
            registers[14] <= THREADS_PER_BLOCK; // %blockDim 
            registers[15] <= THREAD_ID;         // %threadIdx

        end else if (enable) begin 
            // Update the block ID dynamically
            registers[13] <= block_id;
            
            // --- READ ACTION ---
            // When the Scheduler is in State 3 (REQUEST) [cite: 340]
            if (core_state == 3'b011) begin 
                // Look inside the requested slots and push the data out the rs/rt pins [cite: 340, 341]
                rs <= registers[decoded_rs_address]; 
                rt <= registers[decoded_rt_address];
            end

            // --- WRITE ACTION ---
            // When the Scheduler is in State 6 (UPDATE) [cite: 341]
            if (core_state == 3'b110) begin 
                
                // Only write if the Decoder says so, AND thread active is on
                if (decoded_reg_write_enable && decoded_rd_address < 13 && thread_active && warp_active) begin

                    if (decoded_id_read) begin
                        // TID/BID/BDIM: copy a read-only identity register into rd.
                        // Selector reuses the rs field (already {1'b0, instr[8:6]}).
                        case (decoded_rs_address)
                            4'd1: registers[decoded_rd_address] <= registers[15]; // TID  -> threadIdx
                            4'd2: registers[decoded_rd_address] <= registers[13]; // BID  -> blockIdx
                            4'd3: registers[decoded_rd_address] <= registers[14]; // BDIM -> blockDim
                            default: registers[decoded_rd_address] <= registers[15];
                        endcase
                    end else begin
                        // The Multiplexer: Which incoming wire are we saving? [cite: 342]
                        case (decoded_reg_input_mux)
                            ARITHMETIC: begin
                                registers[decoded_rd_address] <= alu_out; // Save ALU answer [cite: 342]
                            end
                            MEMORY: begin
                                registers[decoded_rd_address] <= lsu_out; // Save Memory answer [cite: 343]
                            end
                            CONSTANT: begin
                                registers[decoded_rd_address] <= decoded_immediate; // Save raw number [cite: 344]
                            end
                            MAC: begin
                                registers[decoded_rd_address] <= mac_result; // Save 3x3 MAC result
                            end
                        endcase
                    end
                end
            end
        end
    end
endmodule