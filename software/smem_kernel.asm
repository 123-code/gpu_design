// Shared memory + barrier test (test/tb_smem.sv). 2 warps x 4 lanes.
//
// Every thread writes v(tid) = 1000*tid + blockIdx + 7 (a 16-bit value) into
// its shared-memory slot, then reads the slot of thread (tid+1) % 8 -- which
// for tid 3 and tid 7 belongs to the OTHER warp -- and stores it to main
// memory at 32 + 2*tid (low byte, high byte).
//
// The BAR is what makes that read safe: the scheduler favours warp 0, so
// without it warp 0 reads warp 1's slots before warp 1 has written them.
// smem_nobar_kernel.asm is this file minus the BAR; the testbench shows it
// failing.
        TID  R1
        BID  R2
        LDI  R3, #1000
        MUL  R3, R3, R1      // 1000*tid
        ADD  R3, R3, R2      // + blockIdx
        ADDI R3, R3, #7      // v(tid)
        ADD  R4, R1, R1      // R4 = my slot (byte address 2*tid)
        STS  R3, [R4]
        BAR                  // every warp's slot is written past here
        ADDI R5, R1, #1      // (tid + 1) % 8, without an AND
        MOV  R6, #3
        SHR  R7, R5, R6
        SHL  R7, R7, R6
        SUB  R5, R5, R7
        ADD  R5, R5, R5      // neighbour's slot
        LDS  R0, [R5]        // R0 = v((tid+1) % 8)
        WBASE #32
        STR  R0, [R4]        // main[32 + 2*tid]     = low byte
        MOV  R7, #8
        SHR  R0, R0, R7
        ADDI R4, R4, #1
        STR  R0, [R4]        // main[32 + 2*tid + 1] = high byte
        RET
