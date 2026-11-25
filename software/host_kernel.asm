// GPU kernel the host CPU launches (software/fw/host.c): grid of 2 blocks,
// 1 warp x 4 lanes. Element i = 4*blockIdx + tid: y = x*x + blockIdx, with
// x read from global memory at 2i and y written to global memory at 64 + 2i.
        TID  R1
        BID  R2
        ADD  R3, R2, R2
        ADD  R3, R3, R3      // 4*bid
        ADD  R3, R3, R1      // i
        ADD  R3, R3, R3      // 2i
        LDG  R4, [R3]
        MUL  R4, R4, R4
        ADD  R4, R4, R2
        MOV  R5, #63
        ADDI R5, R5, #1      // 64
        ADD  R3, R3, R5
        STG  R4, [R3]
        RET
