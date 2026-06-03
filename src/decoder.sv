`default_nettype none
`timescale 1ns/1ns

module decoder (
    // ==========================================
    // PART 1: THE INPUT PINS (Wires coming IN)
    // ==========================================
    input wire clk,              // The heartbeat of the system (27MHz on the Tang Nano)
    input wire reset,            // The physical reset button/signal
    
    input wire [2:0] core_state,
    input wire [15:0] instruction,
    
    // ==========================================
    // PART 2: THE OUTPUT PINS (Wires going OUT)
    // ==========================================
    // Group A: Data Slices (routing chunks of the instruction to other places)
    output reg [3:0] decoded_rd_address,
    output reg [3:0] decoded_rs_address,
    output reg [3:0] decoded_rt_address,
    output reg [2:0] decoded_nzp,
    output reg [7:0] decoded_immediate,
    
    // Group B: Control Flags (1-bit boolean wires turning other components ON/OFF)
    output reg decoded_reg_write_enable,           
    output reg decoded_mem_read_enable,            
    output reg decoded_mem_write_enable,           
    output reg decoded_nzp_write_enable,           
    
    // Group C: Multiplexers (Multi-bit wires telling components HOW to behave)
    output reg [1:0] decoded_reg_input_mux,
    output reg [1:0] decoded_alu_arithmetic_mux,
    output reg decoded_alu_output_mux,
    output reg decoded_pc_mux,
    output reg decoded_ret,

    // MAC unit control: push an operand into the MAC buffer this instruction
    output reg decoded_mac_load,

    // Address unit: add decoded_immediate to the LSU base pointer this instruction
    output reg decoded_base_add,

    // FC-MAC coprocessor control (opcode 0000 sub-functions)
    output reg decoded_fc_clear,   // FCLR: acc <- 0
    output reg decoded_fc_mac,     // FMAC: acc += rs*rt
    output reg decoded_fc_read     // FRD : rd <- sat(acc>>Q) (uses the MAC writeback mux)
);

    // Human-readable labels for the physical 4-bit Opcode wire combinations
    localparam FCU  = 4'b0000; // FC-MAC coprocessor; sub-function in instruction[5:4]
    localparam ADD  = 4'b0001;
    localparam MOV  = 4'b0010;
    localparam CMP  = 4'b0011;
    localparam LDR  = 4'b0100;
    localparam ADDI = 4'b0101;
    localparam MUL  = 4'b1010; // general arithmetic primitives (rd = rs op rt)
    localparam SHR  = 4'b1100;
    localparam SHL  = 4'b1101;
    localparam SUB  = 4'b1110;
    localparam MACL = 4'b0110; // push a register into the MAC operand buffer
    localparam MAC  = 4'b0111; // fire the MAC, write result to rd
    localparam BRn  = 4'b1000;
    localparam ADDB = 4'b1001; // base += immediate (data-memory base pointer)
    localparam STR  = 4'b1011; // store/emit: write rt to [rs] (MMIO TX when rs==63)
    localparam RET  = 4'b1111;

    // decoded_reg_input_mux selectors (must match registers.sv)
    localparam MUX_ARITHMETIC = 2'b00;
    localparam MUX_MEMORY     = 2'b01;
    localparam MUX_CONSTANT   = 2'b10;
    localparam MUX_MAC        = 2'b11;

    // ==========================================
    // PART 3: THE INTERNAL LOGIC MACHINERY
    // ==========================================
    // This block tells the hardware: "Every time the 'clk' pin voltage goes from LOW to HIGH, do this."
    always @(posedge clk) begin 
        
        // If the reset pin is triggered, turn all output wires OFF (0 Volts)
        if (reset) begin
            decoded_rd_address <= 0;
            decoded_rs_address <= 0;
            decoded_rt_address <= 0;
            decoded_nzp <= 0;
            decoded_immediate <= 0;

            decoded_reg_write_enable <= 0;
            decoded_mem_read_enable <= 0;
            decoded_mem_write_enable <= 0;
            decoded_nzp_write_enable <= 0;

            decoded_reg_input_mux <= 0;
            decoded_alu_arithmetic_mux <= 0;
            decoded_alu_output_mux <= 0;
            decoded_pc_mux <= 0;
            decoded_ret <= 0;
            decoded_mac_load <= 0;
            decoded_base_add <= 0;
            decoded_fc_clear <= 0;
            decoded_fc_mac <= 0;
            decoded_fc_read <= 0;

        end else begin
            // Only trigger the logic machinery if the 3 core_state wires read '010' (State 2)
            if (core_state == 3'b010) begin 
                
                // --- THE BIT SLICER ---
                // Physically branching wires from the 16-lane 'instruction' bus to the output pins

                // Grabbing exactly 3 bits for registers to match the assembler ISA
                decoded_rd_address <= {1'b0, instruction[11:9]}; // dest  -> [11:9]
                decoded_rs_address <= {1'b0, instruction[8:6]};  // src1  -> [8:6]
                decoded_rt_address <= {1'b0, instruction[2:0]};  // src2  -> [2:0]

                // The immediate payload is the bottom 6 bits (assembler emits 6-bit imm)
                decoded_immediate  <= {2'b0, instruction[5:0]};
                decoded_nzp        <= instruction[11:9];

                // Reset control wires to 0 before the switch logic applies.
                // Every strobe must be cleared here, or a flag set by one
                // instruction (e.g. pc_mux on BRn) would stick on the next one.
                decoded_reg_write_enable <= 0;
                decoded_mem_read_enable  <= 0;
                decoded_mem_write_enable <= 0;
                decoded_nzp_write_enable <= 0;
                decoded_alu_arithmetic_mux <= 0;
                decoded_alu_output_mux <= 0;
                decoded_reg_input_mux <= 0;
                decoded_pc_mux <= 0;
                decoded_ret <= 0;
                decoded_mac_load <= 0;
                decoded_base_add <= 0;
                decoded_fc_clear <= 0;
                decoded_fc_mac <= 0;
                decoded_fc_read <= 0;

                // --- THE OPCODE SWITCH ---
                // Look at the top 4 wires of the instruction (bits 15, 14, 13, 12)
                case (instruction[15:12])
                    FCU: begin
                        // FC-MAC coprocessor. Sub-function in instruction[5:4]:
                        //   00 FCLR  -> clear acc
                        //   01 FMAC  -> acc += rs*rt   (rs=[8:6], rt=[2:0])
                        //   10 FRD   -> rd <- sat(acc>>Q) via the MAC writeback mux
                        case (instruction[5:4])
                            2'b00: decoded_fc_clear <= 1;
                            2'b01: decoded_fc_mac   <= 1;
                            2'b10: begin
                                decoded_reg_write_enable <= 1;
                                decoded_reg_input_mux    <= MUX_MAC;
                                decoded_fc_read          <= 1;
                            end
                            default: ; // reserved
                        endcase
                    end
                    ADD: begin
                        // rs + rt -> rd
                        decoded_reg_write_enable <= 1;
                    end
                    ADDI: begin
                        // rs + immediate -> rd (ALU selects imm via the opcode)
                        decoded_reg_write_enable <= 1;
                    end
                    MUL, SUB, SHR, SHL: begin
                        // General ALU ops: rd = rs (op) rt, written via ARITHMETIC mux
                        decoded_reg_write_enable <= 1;
                    end
                    MOV: begin 
                        decoded_reg_write_enable <= 1;        
                    end
                    CMP: begin
                        // Compares don't save to registers; they save N/Z/P flags.
                        decoded_reg_write_enable <= 0;
                        decoded_nzp_write_enable <= 1; // tell pc.sv to latch the flags
                        decoded_alu_output_mux   <= 1; // ALU emits flags, not a number
                    end
                    LDR: begin
                        // Load: read from memory, then write the result back to rd
                        decoded_reg_write_enable <= 1;
                        decoded_mem_read_enable  <= 1;
                        decoded_reg_input_mux    <= MUX_MEMORY;
                    end
                    MACL: begin
                        // Push rs into the MAC operand buffer (no register write)
                        decoded_mac_load <= 1;
                    end
                    MAC: begin
                        // Fire the MAC and write its result into rd
                        decoded_reg_write_enable <= 1;
                        decoded_reg_input_mux    <= MUX_MAC;
                    end
                    BRn: begin
                        // Branch: tell pc.sv to route the jump target into the PC
                        // (gated by the saved N/Z/P flags vs decoded_nzp). The target
                        // is 8-bit (instruction[7:0]) so it can reach the whole 256-word
                        // ROM, not just the low 64 the generic 6-bit immediate allows.
                        decoded_pc_mux   <= 1;
                        decoded_immediate <= instruction[7:0];
                    end
                    ADDB: begin
                        // Advance the data-memory base pointer by the immediate.
                        decoded_base_add <= 1;
                    end
                    STR: begin
                        // Store/emit: the LSU writes rt to the address in rs
                        // (rs == 63 routes to the memory-mapped UART TX).
                        decoded_mem_write_enable <= 1;
                    end
                    RET: begin 
                        decoded_ret <= 1;                     
                    end
                endcase
            end
        end
    end
endmodule