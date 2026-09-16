// facc_test — prove FACC reads the raw 32-bit FC accumulator, signed.
//
// FARG folds the accumulator into the argmax and clears it, which is all a
// FINAL classifier layer needs. A HIDDEN layer has to read its own dot product
// back, requantize it, and store it as the next layer's input — so fc_mac now
// exposes `acc` and FACC Rd,#n reads byte n of it (same readback slot as FBEST;
// instruction bit 3 picks acc over best_idx).
//
// Phase 1: weight +20, pixel 30, 8 taps ->  8*30*20  =  4800 = 0x000012C0
// Phase 2: weight 0xFF (= -1 signed),    ->  8*30*-1 =  -240 = 0xFFFFFF10
// Phase 2 is the one that matters: a hidden layer's pre-activation is routinely
// negative, and ReLU needs the sign to survive the readback.
//
// Phase 3: FOUT R4,#0 on acc=4800    ->  4800>>8  =   18   (normal requantize)
// Phase 4: FOUT R5,#0 on acc=-240    ->  ReLU     =    0   (negative clamps low)
// Phase 5: FOUT R6,#0 on acc=259080  ->  1012     =  255   (saturates high)
//
// Emits [len=11][p1 b0..b3][p2 b0..b3][p3][p4][p5], little-endian.
// Run at 1 WARP: the FC-MAC accumulator is thread-0 driven, so 2 warps would
// double-drive every FMAC.

        MOV  R0, #20        // weight (signed int8, positive)
        MOV  R1, #30        // pixel  (unsigned)

        FRST                // acc <- 0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0

        FACC R4, #0         // acc[7:0]
        FACC R5, #1         // acc[15:8]
        FACC R6, #2         // acc[23:16]
        FACC R7, #3         // acc[31:24]

        MOV  R2, #63        // MMIO UART TX offset
        MOV  R3, #11        // frame length = 11 result bytes
        STR  R3, [R2]
        STR  R4, [R2]
        STR  R5, [R2]
        STR  R6, [R2]
        STR  R7, [R2]

        FRST                // acc <- 0 for the negative phase
        LDI  R0, #255       // weight = 0xFF = -1 signed (MOV imm is only 6-bit)
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0

        FACC R4, #0
        FACC R5, #1
        FACC R6, #2
        FACC R7, #3
        STR  R4, [R2]
        STR  R5, [R2]
        STR  R6, [R2]
        STR  R7, [R2]

// ---- phase 3: requantize a positive accumulator ----
        FRST
        MOV  R0, #20        // weight +20 again (R1 is still 30)
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FOUT R4, #0         // clamp(4800 >>> 8) = 18 ; also clears acc
        STR  R4, [R2]

// ---- phase 4: ReLU a negative accumulator ----
        FRST
        LDI  R0, #255       // weight -1
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FOUT R5, #0         // -240 >>> 8 = -1 -> ReLU -> 0
        STR  R5, [R2]

// ---- phase 5: saturate a large accumulator ----
        FRST
        LDI  R0, #127       // max positive int8 weight
        LDI  R1, #255       // max unsigned pixel
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FMAC R1, R0
        FOUT R6, #0         // 259080 >>> 8 = 1012 -> saturates to 255
        STR  R6, [R2]

        RET
        RET                 // sacrificial: the UART->DMA loader can drop the last word
