; bench_ops: throughput benchmark for measuring real ALU ops/s on the FPGA.
; Nested loop; the body is 16 pure-ALU ops (no memory) so it takes the trimmed
; 6-cycle path. All lanes run it in lockstep (uniform loop bound -> no divergence).
;   outer count = mem[0], inner count = mem[1]  (streamed as data, so the PROGRAM
;   is identical across runs -> timing the slope vs outer-count cancels all fixed
;   UART/load/reply overhead and isolates pure GPU compute time).
; Total ALU body-ops executed (per lane) = outer * inner * 16.
; Emits a 1-byte marker at the end so the host knows it finished.
        TID  R1            ; per-lane seed (lanes differ; values irrelevant to timing)
        MOV  R4, #1        ; constant 1
        MOV  R0, #0
        LDR  R6, [R0]      ; R6 = outer limit (mem[0])
        MOV  R0, #1
        LDR  R7, [R0]      ; R7 = inner limit (mem[1])
        MOV  R5, #0        ; outer counter
outer:  MOV  R3, #0        ; inner counter
inner:  ADD  R1, R1, R4    ; ---- 16-op compute body ----
        MUL  R2, R1, R1
        ADD  R1, R1, R4
        MUL  R2, R1, R1
        ADD  R1, R1, R4
        MUL  R2, R1, R1
        ADD  R1, R1, R4
        MUL  R2, R1, R1
        ADD  R1, R1, R4
        MUL  R2, R1, R1
        ADD  R1, R1, R4
        MUL  R2, R1, R1
        ADD  R1, R1, R4
        MUL  R2, R1, R1
        ADD  R1, R1, R4
        MUL  R2, R1, R1    ; ---- end body (16 ALU ops) ----
        ADD  R3, R3, R4    ; inner++
        CMP  R3, R7
        BRn  inner         ; while inner < R7
        ADD  R5, R5, R4    ; outer++
        CMP  R5, R6
        BRn  outer         ; while outer < R6
        MOV  R0, #63       ; ---- emit done marker ----
        MOV  R2, #1
        STR  R2, [R0]
        STR  R1, [R0]
        RET
