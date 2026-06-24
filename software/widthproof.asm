; widthproof: confirm the MAX (24-lane) bitstream is live on hardware.
; Lane 0 of each core reads %blockDim (the launch width = 12 in the max config),
; squares it via MUL (exercises the hard DSP multiplier), and emits both:
;     reply per core = [len=2][blockDim][blockDim*blockDim]
;                    = [2][12][144]  ->  02 0c 90
; Two cores -> the host sees that frame twice. Straight-line (no branches) so it
; is robust regardless of launch geometry. Per-lane parallelism itself is proven
; in sim (tb_tid12: all 12 lanes hold distinct IDs) because this microarch funnels
; all memory writes / UART emits through thread 0.
        BDIM R1            ; R1 = blockDim (12 in the max config)
        MUL  R2, R1, R1    ; R2 = 12*12 = 144  (0x90) via DSP
        MOV  R0, #63       ; R0 = MMIO emit offset
        MOV  R3, #2        ; length = 2 result bytes
        STR  R3, [R0]      ; emit len
        STR  R1, [R0]      ; emit blockDim
        STR  R2, [R0]      ; emit blockDim^2
        RET
