// t -> R0
TID R0
// big -> R1
LDI R1, #200
// m -> R2
MOV R6, #2
CMP R0, R6
BRn Lmax1
ADDI R6, R0, #0
Lmax1:
SYNC
ADDI R2, R6, #0
// r -> R3
MOV R3, #5
MOV R6, #2
CMP R0, R6
BRzp Lskip2
ADDI R3, R1, #1
Lskip2:
SYNC
// after -> R4
MOV R4, #7
MOV R6, #5
CMP R1, R6
BRzp Lskip3
LDI R4, #99
Lskip3:
SYNC
LDI R6, #200
CMP R1, R6
BRnp Lskip4
ADDI R4, R4, #1
Lskip4:
SYNC
// wide -> R5
LDI R6, #100
ADD R5, R1, R6
RET
RET
