; Write-path roundtrip: store 42 to data mem, read it back, emit it.
        MOV   R0, #0       ; offset 0
        WBASE #20          ; write base = 20
        MOV   R2, #42      ; value
        STR   R2, [R0]     ; mem[wbase+0 = 20] = 42   (real BRAM write)
        ADDB  #20          ; read base = 20
        LDR   R3, [R0]     ; R3 = mem[rbase+0 = 20]
        MOV   R1, #63
        STR   R3, [R1]     ; emit R3 (expect 42)
        RET
