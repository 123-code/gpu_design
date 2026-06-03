; ============================================================================
; FULL on-chip MNIST: Conv -> Pool -> Scatter -> FC -> emit  (built in stages)
; ============================================================================
; Memory map (8192 B, ADDR_BITS=13):
;   0    .. 783   28x28 image            (host streams; sim preloads)
;   1024 .. 1699  26x26 conv map         (GPU writes via wbase)
;   1700 .. 1868  13x13 pooled map        (GPU writes via wbase)
;   2048 .. 5427  FC buffer [feat,weight]x1690 (weights baked; features scattered)
; Conv weights are baked into the MAC coprocessor; FC weights baked in the buffer;
; biases baked in the FC-MAC ROM. The host streams only the 784-byte image.
;
; Registers: R0=0 const | R1 offset | R2 x/col | R3 y/row | R4 pixel | R5 result
;            R6 limit | R7 scratch
; ============================================================================

        MOV   R0, #0
        MOV   R6, #26              ; conv loop limit (26x26)

; ---- prologue: set write base = CONV_BASE (1024) = 16*63 + 16 ----
        MOV   R5, #16
        MOV   R7, #0
WBINIT: WBASE #63
        ADDI  R7, R7, #1
        CMP   R7, R5
        BRn   WBINIT              ; 16 x 63 = 1008
        WBASE #16                 ; wbase = 1024  (CONV_BASE)

; ============================================================================
; PHASE 1 - CONVOLUTION (3x3 valid, 28x28 -> 26x26). rbase sweeps the image.
; ============================================================================
        MOV   R3, #0              ; y (row)
CY:     MOV   R2, #0              ; x (col)
CX:     MOV   R1, #0              ; --- gather 3x3 window: 9x (LDR pixel; MACL) ---
        LDR   R4, [R1]
        MACL  R4
        MOV   R1, #1
        LDR   R4, [R1]
        MACL  R4
        MOV   R1, #2
        LDR   R4, [R1]
        MACL  R4
        MOV   R1, #28
        LDR   R4, [R1]
        MACL  R4
        MOV   R1, #29
        LDR   R4, [R1]
        MACL  R4
        MOV   R1, #30
        LDR   R4, [R1]
        MACL  R4
        MOV   R1, #56
        LDR   R4, [R1]
        MACL  R4
        MOV   R1, #57
        LDR   R4, [R1]
        MACL  R4
        MOV   R1, #58
        LDR   R4, [R1]
        MACL  R4

        MAC   R5                  ; fire 3x3 MAC -> R5 (ReLU + quantized 8-bit)
        STR   R5, [R0]            ; conv_map[wbase] = R5
        WBASE #1                  ; advance write pointer
        ADDB  #1                  ; slide window right one pixel

        ADDI  R2, R2, #1
        CMP   R2, R6              ; col < 26 ?
        BRn   CX
        ADDB  #2                  ; row gap: skip the 2 unused right-edge columns
        ADDI  R3, R3, #1
        CMP   R3, R6              ; row < 26 ?
        BRn   CY

; ============================================================================
; PHASE 2 - MAX POOL (2x2 stride 2, 26x26 -> 13x13). rbase sweeps the conv map.
; After conv: rbase = 728 (end of image sweep), wbase = 1700 (= POOL_BASE).
; Reposition rbase forward to CONV_BASE (1024): 728 + 296.
; ============================================================================
        ADDB  #63
        ADDB  #63
        ADDB  #63
        ADDB  #63
        ADDB  #44                ; rbase = 1024 (CONV_BASE)
        MOV   R6, #13            ; pooled loop limit (13x13)
        MOV   R3, #0             ; Y
PY:     MOV   R2, #0             ; X
PX:     MOV   R1, #0
        LDR   R4, [R1]           ; conv[2Y  ][2X  ]
        MOV   R1, #1
        LDR   R5, [R1]           ; conv[2Y  ][2X+1]
        MAX   R4, R4, R5
        MOV   R1, #26
        LDR   R5, [R1]           ; conv[2Y+1][2X  ]
        MOV   R1, #27
        LDR   R7, [R1]           ; conv[2Y+1][2X+1]
        MAX   R5, R5, R7
        MAX   R4, R4, R5         ; pooled = max of the 2x2 window
        STR   R4, [R0]           ; pooled[wbase] = R4
        WBASE #1
        ADDB  #2                 ; stride 2 across conv columns
        ADDI  R2, R2, #1
        CMP   R2, R6             ; X < 13 ?
        BRn   PX
        ADDB  #26                ; skip one conv row (pool row stride = 2 rows)
        ADDI  R3, R3, #1
        CMP   R3, R6             ; Y < 13 ?
        BRn   PY

; ============================================================================
; PHASE 3 - SCATTER pooled features into the baked FC buffer's even slots.
; After pool: rbase = 1700 (= POOL_BASE, perfect for reading pooled[i] by offset),
; wbase = 1869. Reposition wbase forward to FC_BUF_BASE (2048): 1869 + 179.
; ============================================================================
        WBASE #63
        WBASE #63
        WBASE #53                ; wbase = 2048 (FC_BUF_BASE)
        MOV   R7, #63            ; build inner limit = 169
        ADDI  R7, R7, #63
        ADDI  R7, R7, #43        ; R7 = 169
        MOV   R3, #0             ; d (digit) 0..9
SD:     MOV   R1, #0             ; i (feature index) 0..168
SI:     LDR   R4, [R1]           ; feature = pooled[rbase(1700) + i]
        STR   R4, [R0]           ; FC_buf[wbase] = feature (even slot)
        WBASE #2                 ; skip the baked weight slot
        ADDI  R1, R1, #1
        CMP   R1, R7             ; i < 169 ?
        BRn   SI
        ADDI  R3, R3, #1
        MOV   R6, #10
        CMP   R3, R6             ; d < 10 ?
        BRn   SD

; ============================================================================
; PHASE 4 - FULLY CONNECTED + argmax. Reposition rbase 1700 -> 2048 (+348),
; then sweep the now-complete [feature, weight] buffer through the FC-MAC.
; ============================================================================
        ADDB  #63
        ADDB  #63
        ADDB  #63
        ADDB  #63
        ADDB  #63
        ADDB  #33                ; rbase = 2048 (FC_BUF_BASE)
        FRST                     ; reset FC engine
        MOV   R3, #0             ; class 0..9
FCC:    MOV   R6, #13
        MOV   R5, #0             ; row
FCR:    MOV   R2, #0             ; col
FCL:    LDR   R4, [R0]           ; feature
        ADDB  #1
        LDR   R7, [R0]           ; weight
        ADDB  #1
        FMAC  R4, R7             ; acc += feature * weight
        ADDI  R2, R2, #1
        CMP   R2, R6
        BRn   FCL
        ADDI  R5, R5, #1
        CMP   R5, R6
        BRn   FCR
        FARG                     ; score = acc + bias[class]; argmax; next digit
        ADDI  R3, R3, #1
        MOV   R6, #10
        CMP   R3, R6
        BRn   FCC

        FBEST R3                 ; R3 = predicted digit
        MOV   R1, #63
        STR   R3, [R1]           ; emit prediction over UART
        RET
