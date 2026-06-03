; ============================================================================
; MNIST FC + argmax classifier, on-chip (conv/pool precomputed off-line).
; ============================================================================
; The GPU has no main-memory WRITE path (LSU STR only emits to UART), so the
; conv->pool front-end is computed by software/mnist_ref.py and its 169 pooled
; features are streamed in. This kernel runs the trained FC layer + argmax on
; the FC-MAC coprocessor and emits the predicted digit.
;
; Data memory (streamed in by the DMA, then base-swept by this kernel):
;   for digit d = 0..9, for input i = 0..168:
;       [ feature[i] , fc_weight[d*169 + i] ]            (3380 bytes total)
; Features repeat per digit because the LSU base pointer (ADDB) only advances,
; so the whole FC pass is one monotonic forward sweep. Biases (int32) live in
; the FC-MAC coprocessor's ROM (bias.hex), indexed by its internal digit counter.
;
; Registers (R0..R7 addressable): R0=0 (LDR offset) | R2 col | R3 digit |
;   R4 feature | R5 weight | R6 row | R7 loop limit
; ============================================================================

        MOV   R0, #0          ; const 0: LDR [R0] reads mem[base + 0]
        FRST                  ; reset FC engine: acc=0, digit=0, best=-inf

        MOV   R3, #0          ; digit counter (0..9)
DIGIT:
        MOV   R7, #13         ; 13 x 13 = 169 inputs per digit
        MOV   R6, #0          ; inner row
ROW:
        MOV   R2, #0          ; inner col
COL:
        LDR   R4, [R0]        ; feature = mem[base]
        ADDB  #1              ; advance to the weight
        LDR   R5, [R0]        ; weight  = mem[base]
        ADDB  #1              ; advance to next (feature,weight) pair
        FMAC  R4, R5          ; acc += feature * weight   (32-bit signed)

        ADDI  R2, R2, #1
        CMP   R2, R7          ; col < 13 ?
        BRn   COL
        ADDI  R6, R6, #1
        CMP   R6, R7          ; row < 13 ?
        BRn   ROW

        FARG                  ; finalize this digit: score=acc+bias[digit]; argmax

        ADDI  R3, R3, #1
        MOV   R7, #10
        CMP   R3, R7          ; digit < 10 ?
        BRn   DIGIT

        FBEST R3              ; R3 = predicted digit (argmax winner)
        MOV   R1, #63
        STR   R3, [R1]        ; emit the digit over UART
        RET
