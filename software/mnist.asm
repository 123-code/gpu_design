; ======================================================================
; FULL MNIST CLASSIFIER - CUSTOM GPU ASSEMBLY
; ======================================================================

; ----------------------------------------------------------------------
; PHASE 1: CONVOLUTION LAYER (Using MAC Coprocessor)
; Input: 28x28 Image (784 bytes)
; Output: 26x26 Feature Map (676 bytes) saved to BRAM
; ----------------------------------------------------------------------
CONV_START:
    ; (Assume weights are already loaded into MAC buffer)
    ADDB #9               ; Move Base pointer to the start of the image
    
    ; Loop 676 times (26x26)
CONV_LOOP:
    MOV R1, #0            ; Offset 0
    LDR R5, [R1]          
    MACL R5               ; Load Pixel 0 into MAC Coprocessor
    ; ... (Repeat MACL for all 9 window offsets) ...
    
    MAC R3                ; FIRE COPROCESSOR: R3 = Convolution result
    
    MOV R2, #100          ; Set offset to our intermediate BRAM storage
    STR R3, [R2]          ; Save the calculated pixel to memory
    
    ADDB #1               ; Slide window right 1 pixel
    ; (Loop branching logic omitted for brevity)

; ----------------------------------------------------------------------
; PHASE 2: MAX POOLING LAYER (Using General ALU)
; Input: 26x26 Feature Map (676 bytes)
; Output: 13x13 Pooled Map (169 bytes) saved to BRAM
; ----------------------------------------------------------------------
POOL_START:
    ; Reset Base pointer to the start of the 26x26 Feature Map
    ; Loop 169 times (13x13)
POOL_LOOP:
    ; Fetch the 4 pixels in a 2x2 grid
    MOV R1, #0
    LDR R4, [R1]          ; Top-Left pixel
    MOV R1, #1
    LDR R5, [R1]          ; Top-Right pixel
    MOV R1, #26
    LDR R6, [R1]          ; Bottom-Left pixel
    MOV R1, #27
    LDR R7, [R1]          ; Bottom-Right pixel

    ; Run General ALU Comparators
    MAX R4, R4, R5        ; R4 now holds the winner of the top row
    MAX R6, R6, R7        ; R6 now holds the winner of the bottom row
    MAX R4, R4, R6        ; R4 now holds the absolute highest pixel of the 4
    
    ; Save the single winning pixel back to memory
    MOV R2, #200
    STR R4, [R2]          
    
    ADDB #2               ; Slide window right by 2 (Pooling Stride)

; ----------------------------------------------------------------------
; PHASE 3: FULLY CONNECTED LAYER (Using General ALU)
; Input: 13x13 Pooled Map (169 bytes)
; Output: 10 Final Scores (Digit 0 through 9)
; ----------------------------------------------------------------------
FC_START:
    ; Here we loop 10 times (once for each possible digit)
    ; For each digit, we multiply the 169 pooled pixels by 169 unique weights
    ; (Weights are loaded from the newly mapped second BRAM block)
    
    ; MUL R_pixel, R_weight
    ; ADD R_score, R_score, R_result
    
    ; (After 10 loops, Registers R10 through R19 hold the total scores for digits 0-9)

; ----------------------------------------------------------------------
; PHASE 4: ARGMAX & EMIT (The Final Prediction)
; ----------------------------------------------------------------------
OUTPUT_START:
    ; Find which digit got the highest score using the MAX instruction
    ; (e.g., if R17 holds the highest score, the network predicts a '7')
    
    ; Assume R_WINNER ends up holding the number 7
    
    ; Trigger the UART Trapdoor
    MOV R1, #63           ; Load the Sentinel Offset (63)
    STR R_WINNER, [R1]    ; FIRE UART: Send '7' down the USB cable to the Mac!
    
    RET                   ; Halt execution