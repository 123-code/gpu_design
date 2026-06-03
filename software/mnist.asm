; ============================================================================
; FULL MNIST CLASSIFIER  -  tiny-gpu assembly  (architecture draft)
; ============================================================================
; Pipeline:  Conv(3x3 MAC) -> ReLU/quant -> MaxPool(2x2) -> FC(169->10) -> argmax
;
; Memory map (4096-byte main_memory, ADDR_BITS=12). DMA loads 0..2492 from the
; host contiguously; the GPU computes the scratch regions above 2492.
;   0    .. 783    28x28 input image                 (DMA)
;   784  .. 792    9 conv weights (into MAC buffer)  (DMA)
;   793  .. 2482   FC weights, 169 x 10 row-major     (DMA)
;   2483 .. 2492   10 FC biases                       (DMA)
;   CONV_MAP @ ~2493  26x26 feature map  (GPU writes)
;   POOL_MAP @ ~3169  13x13 pooled map   (GPU writes)
;   SCORES   @ ~3338  10 digit scores    (GPU writes)
;   [63]           memory-mapped UART TX (STR here emits a byte)
;
; ISA constraints baked into the structure:
;   * Only R0..R7 are instruction-addressable (3-bit reg fields); R0 is kept = 0.
;     Registers are REUSED across the four sequential phases.
;   * MOV immediates are 6-bit (<=63) and counters 8-bit, so every loop is NESTED
;     with small limits (26x26, 13x13) instead of one >255 counter.
;   * Only BRn exists, so conditionals are written as "invert compare + skip".
;   * Region base addresses are reached by walking the LSU base pointer with ADDB
;     (#<=63 per step); shown compactly and marked [base].
;   * Pooling/argmax use the MAX pseudo-op (CMP+BRn+ADDI); FC uses the wide
;     FC-MAC coprocessor (FCLR/FMAC/FRD) so 169 signed products don't overflow 8b.
; This draft ASSEMBLES and shows the full loop architecture; [base]/weight-
; preload/bias steps are marked where a final build fills in exact addressing.
; ============================================================================

        MOV   R0, #0                 ; R0 = constant 0 (held for the whole kernel)

; ----------------------------------------------------------------------------
; PHASE 1 - CONVOLUTION  (3x3 over 28x28 -> 26x26 feature map)
;   R1 off | R2 col | R3 row | R4 pixel | R6 result | R7 limit(26)
; ----------------------------------------------------------------------------
CONV:
        ADDB  #63                    ; [base] walk base toward the image region
        MACL  R4                     ; (illustrative) preload 9 conv weights here
        MOV   R7, #26                ; conv map is 26 x 26

        MOV   R3, #0                 ; row counter
CONV_ROW:
        MOV   R2, #0                 ; col counter
CONV_COL:
        ; --- gather the 3x3 window: 9x (LDR pixel ; MACL pixel) ---
        MOV   R1, #0
        LDR   R4, [R1]
        MACL  R4
        MOV   R1, #1
        LDR   R4, [R1]
        MACL  R4                     ; ... repeat for the remaining 7 taps ...

        MAC   R6                     ; fire 3x3 MAC -> R6 (ReLU + quantized 8-bit)
        MOV   R1, #0
        STR   R6, [R1]               ; store feature pixel to CONV_MAP[base]
        ADDB  #1                     ; slide window right one pixel

        ADDI  R2, R2, #1
        CMP   R2, R7                 ; col < 26 ?
        BRn   CONV_COL
        ADDI  R3, R3, #1
        CMP   R3, R7                 ; row < 26 ?
        BRn   CONV_ROW

; ----------------------------------------------------------------------------
; PHASE 2 - MAX POOL  (2x2 stride 2 over 26x26 -> 13x13)
;   R1 off | R2 col | R3 row | R4/R5/R6 pixels+max | R7 limit(13)
; ----------------------------------------------------------------------------
POOL:
        MOV   R7, #13
        MOV   R3, #0                 ; pooled row
POOL_ROW:
        MOV   R2, #0                 ; pooled col
POOL_COL:
        MOV   R1, #0
        LDR   R4, [R1]               ; top-left
        MOV   R1, #1
        LDR   R5, [R1]               ; top-right
        MAX   R4, R4, R5             ; max of top row     (pseudo-op)
        MOV   R1, #26
        LDR   R5, [R1]               ; bottom-left
        MOV   R1, #27
        LDR   R6, [R1]               ; bottom-right
        MAX   R5, R5, R6             ; max of bottom row
        MAX   R4, R4, R5             ; overall 2x2 maximum -> R4
        MOV   R1, #0
        STR   R4, [R1]               ; store to POOL_MAP[base]
        ADDB  #2                     ; stride 2 across the feature map

        ADDI  R2, R2, #1
        CMP   R2, R7
        BRn   POOL_COL
        ADDI  R3, R3, #1
        CMP   R3, R7
        BRn   POOL_ROW

; ----------------------------------------------------------------------------
; PHASE 3 - FULLY CONNECTED  (169 pooled inputs x 10 classes)
;   R2 col | R3 class | R4 pixel | R5 weight | R6 row->score | R7 limit
;   Wide FC-MAC accumulator keeps the 169-term signed sum off the 8-bit datapath.
; ----------------------------------------------------------------------------
FC:
        MOV   R3, #0                 ; class counter (0..9)
FC_CLASS:
        FCLR                         ; acc = 0 for this digit
        MOV   R7, #13                ; 13 x 13 = 169 inner iterations
        MOV   R6, #0                 ; inner row
FC_ROW:
        MOV   R2, #0                 ; inner col
FC_COL:
        MOV   R1, #0
        LDR   R4, [R1]               ; pooled pixel (POOL_MAP[base])
        MOV   R1, #0
        LDR   R5, [R1]               ; FC weight    (FC weights[base'])
        FMAC  R4, R5                 ; acc += pixel * weight  (32-bit signed)
        ADDB  #1                     ; advance to next weight/pixel

        ADDI  R2, R2, #1
        CMP   R2, R7
        BRn   FC_COL
        ADDI  R6, R6, #1
        CMP   R6, R7
        BRn   FC_ROW

        FRD   R6                     ; R6 = saturate(acc >> Q) (requantized score)
        ; ... (add this class's bias from addr 2483+R3) ...
        MOV   R1, #0
        STR   R6, [R1]               ; SCORES[class] = R6

        ADDI  R3, R3, #1
        MOV   R7, #10
        CMP   R3, R7
        BRn   FC_CLASS               ; next class while class < 10

; ----------------------------------------------------------------------------
; PHASE 4 - ARGMAX + EMIT  (scan 10 scores, emit the winning digit on [63])
;   R2 ctr | R3 best idx | R4 best val | R5 score | R7 limit(10)
; ----------------------------------------------------------------------------
ARGMAX:
        MOV   R4, #0                 ; best score so far
        MOV   R3, #0                 ; best index (predicted digit)
        MOV   R2, #0                 ; scan counter
        MOV   R7, #10
ARG_LOOP:
        MOV   R1, #0
        LDR   R5, [R1]               ; SCORES[R2]
        CMP   R5, R4                 ; N set if score < best -> keep current best
        BRn   ARG_KEEP               ; (only BRn exists: invert compare + skip adopt)
        ADD   R3, R2, #0             ; score >= best: best index = current class
        ADD   R4, R5, #0             ; best value = this score
ARG_KEEP:
        ADDI  R2, R2, #1
        CMP   R2, R7
        BRn   ARG_LOOP

        MOV   R1, #63
        STR   R3, [R1]               ; EMIT predicted digit over UART
        RET
