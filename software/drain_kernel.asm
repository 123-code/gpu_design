// Posted-store drain test (test/tb_drain.sv, gridDim = 8, 1 warp x 4 lanes).
// Each lane's LAST act is an STG; the block then RETs at once. The store is
// posted (the L1 write buffer takes it and releases the lane), so it can
// still be in flight when the block finishes -- and the next block's reset
// must not wipe it. Lane t of block b stores 16*b + t + 1 at 512 + 8*b + 2*t.
        TID  R1
        BID  R2
        MOV  R6, #4
        SHL  R3, R2, R6       // 16*b
        ADD  R3, R3, R1
        ADDI R3, R3, #1       // value
        MOV  R6, #3
        SHL  R4, R2, R6       // 8*b
        ADD  R4, R4, R1
        ADD  R4, R4, R1       // + 2t
        LDI  R5, #512
        ADD  R4, R4, R5
        STG  R3, [R4]
        RET
