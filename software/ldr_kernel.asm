// LDR isolation test: pull three streamed bytes out of data memory into
// registers, so the testbench can confirm the Host->Device->LDR path.
//   R5 = mem[0],  R6 = mem[1],  R7 = mem[2]
// (Only R0..R7 are addressable — register fields are 3 bits.)

MOV R1, #0
LDR R5, [R1]      // R5 <- mem[0]
MOV R1, #1
LDR R6, [R1]      // R6 <- mem[1]
MOV R1, #2
LDR R7, [R1]      // R7 <- mem[2]
RET
