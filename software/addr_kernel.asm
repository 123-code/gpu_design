// Wider-addressing test: move the base pointer to 300 (>255, impossible with an
// 8-bit register), then LDR mem[base+0] into R3 and halt.
ADDB #60
ADDB #60
ADDB #60
ADDB #60
ADDB #60
MOV  R1, #0
LDR  R3, [R1]
RET
