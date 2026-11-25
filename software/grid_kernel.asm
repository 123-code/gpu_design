// Grid scheduling test (test/tb_grid.sv, launched with gridDim = 9).
//
// Each block computes val = 7*blockIdx + gridDim, then burns (gridDim-bid)*8
// loop iterations so LOW blocks are the SLOW ones: the core that drew block 0
// is still busy while the other core races through the later blocks. Blocks
// with bid % 3 == 1 emit nothing; everyone else emits [bid][val]. The reply
// must still come back in blockIdx order:
//     [0][9] [2][23] [3][30] [5][44] [6][51] [8][65]
        BID  R1              // R1 = blockIdx
        GDIM R2              // R2 = gridDim
        MOV  R3, #0          // R3 = val
        MOV  R4, #0          // R4 = i
        MOV  R6, #1
loop1:  CMP  R4, R1
        BRzp done1           // i >= bid
        ADDI R3, R3, #7
        ADD  R4, R4, R6
        BR   loop1
done1:  ADD  R3, R3, R2      // val = 7*bid + gridDim

        SUB  R5, R2, R1      // delay = (gridDim - bid) * 8
        MOV  R7, #3
        SHL  R5, R5, R7
        MOV  R4, #0
loop2:  CMP  R4, R5
        BRzp done2
        ADD  R4, R4, R6
        BR   loop2

done2:  ADDI R5, R1, #0      // R5 = bid % 3
        MOV  R7, #3
mod:    CMP  R5, R7
        BRn  modd
        SUB  R5, R5, R7
        BR   mod
modd:   CMP  R5, R6
        BRz  skip            // bid % 3 == 1: no output
        // Only thread 0 talks: thread 0 of EVERY warp drives the UART, so
        // gate on tid (lane 0 branches, the rest reconverge at SYNC).
        TID  R5
        CMP  R5, R6
        BRn  emit            // tid < 1
        SYNC                 // other lanes: reconverge
skip:   RET
emit:   MOV  R0, #63
        STR  R1, [R0]        // emit bid
        STR  R3, [R0]        // emit val
        SYNC                 // back to the waiting lanes
