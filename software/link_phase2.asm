// Two-board all-reduce, phase 2: y = mine + the peer's (it arrived at 256+2i
// during phase 1), stored at 512 + 2i. Both boards end with the same sum.
        TID  R1
        BID  R2
        ADD  R3, R2, R2
        ADD  R3, R3, R3
        ADD  R3, R3, R1
        ADD  R3, R3, R3      // 2i
        LDG  R4, [R3]        // mine
        LDI  R5, #256
        ADD  R5, R5, R3
        LDG  R6, [R5]        // the peer's
        ADD  R4, R4, R6
        LDI  R5, #512
        ADD  R5, R5, R3
        STG  R4, [R5]
        RET
