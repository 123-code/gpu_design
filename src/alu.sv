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

    localparam ADD  = 4'b0001;
    localparam MOV  = 4'b0010;
    localparam CMP  = 4'b0011;
    localparam ADDI = 4'b0101;

    always @(*) begin
        case (opcode)
            ADD:  alu_out = rs + rt;
            ADDI: alu_out = rs + imm; // second operand is the immediate
            MOV:  alu_out = imm;      // Pass the payload directly through!
            // CMP produces the N/Z/P flags that pc.sv latches from alu_out[2:0]:
            //   bit2 = N (rs <  rt), bit1 = Z (rs == rt), bit0 = P (rs > rt)
            CMP: alu_out = {5'b0, (rs < rt), (rs == rt), (rs > rt)};
            default: alu_out = 8'd0;
        endcase
    end

endmodule