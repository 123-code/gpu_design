// General-purpose proof: a software dot product using MUL + ADD (no MAC unit).
//   R3 = 2*3 + 4*5 = 6 + 20 = 26
MOV R1, #2
MOV R2, #3
MUL R5, R1, R2     // R5 = 6
MOV R1, #4
MOV R2, #5
MUL R6, R1, R2     // R6 = 20
ADD R3, R5, R6     // R3 = 26
RET
