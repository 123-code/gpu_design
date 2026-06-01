`default_nettype none
`timescale 1ns/1ns

module alu (
    input wire clk,             
    input wire [3:0] opcode,    
    input wire [7:0] imm,       
    input wire [7:0] rs,        
    input wire [7:0] rt,        
    output reg [7:0] alu_out    
);

    // General-purpose arithmetic/logic primitives. Multiply is now a single
    // instruction the software composes (e.g. a dot product = MUL + ADD), not a
    // baked unit. The 3x3 MAC remains as an optional coprocessor (see core.sv).
    localparam ADD  = 4'b0001;
    localparam MOV  = 4'b0010;
    localparam CMP  = 4'b0011;
    localparam ADDI = 4'b0101;
    localparam MUL  = 4'b1010;
    localparam SHR  = 4'b1100;
    localparam SHL  = 4'b1101;
    localparam SUB  = 4'b1110;

    always @(*) begin
        case (opcode)
            ADD:  alu_out = rs + rt;
            SUB:  alu_out = rs - rt;
            MUL:  alu_out = rs * rt;  // low 8 bits of the product
            SHR:  alu_out = rs >> rt[2:0];
            SHL:  alu_out = rs << rt[2:0];
            ADDI: alu_out = rs + imm; // second operand is the immediate
            MOV:  alu_out = imm;      // Pass the payload directly through!
            // CMP produces the N/Z/P flags that pc.sv latches from alu_out[2:0]:
            //   bit2 = N (rs <  rt), bit1 = Z (rs == rt), bit0 = P (rs > rt)
            CMP: alu_out = {5'b0, (rs < rt), (rs == rt), (rs > rt)};
            default: alu_out = 8'd0;
        endcase
    end

endmodule