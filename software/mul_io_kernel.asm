// General-purpose demo: read two operands from memory, multiply with the MUL
// primitive (one instruction), emit the product. Stream 2 bytes -> get a*b.
MOV R1, #0
LDR R4, [R1]      // R4 = mem[0] = a
MOV R1, #1
LDR R2, [R1]      // R2 = mem[1] = b
MUL R3, R4, R2    // R3 = a * b   (single general MUL instruction)
MOV R1, #63
STR R3, [R1]      // emit a*b over UART
RET
