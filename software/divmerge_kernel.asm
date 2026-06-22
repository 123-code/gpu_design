// Reconvergence test: a diamond followed by COMMON code that all lanes must run.
//   lanes 0,1 -> branch (R3=10), lanes 2,3 -> stay (R3=20)   [divergence]
//   then ALL lanes run: R4 = 7                                [reconvergence]
// Correct: R3=[10,10,20,20], R4=[7,7,7,7].
        TID  R1
        MOV  R2, #2
        CMP  R1, R2
        BRn  iftrue        // branch lanes(0,1) -> iftrue; stay(2,3) pushed
        MOV  R3, #20       // stay block (runs 2nd)
        SYNC               // stack empties -> fall into common
        MOV  R4, #7        // COMMON: every lane should set R4=7
        RET
iftrue: MOV  R3, #10       // branch block (runs 1st)
        SYNC               // pop -> stay block
