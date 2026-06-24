; mlp_parallel: tiny FC layer, ONE NEURON PER LANE (N=9). Demo for the per-lane
; write path (lsu_write_arbiter): each lane computes y[tid]=in0*W[tid][0]+in1*W[tid][1]
; and STOREs its own result to mem[32+tid]. Lane 0 streams the 9 outputs out.
; in0=2,in1=3,W[tid]=[tid,1] -> y[tid]=2*tid+3. Run at WARPS=1/TPB=9/BLOCK_DIM=9.

        TID  R1
        ADD  R2, R1, R1
        MOV  R0, #2
        ADD  R2, R2, R0
        LDR  R3, [R2]
        MOV  R0, #1
        ADD  R0, R2, R0
        LDR  R4, [R0]
        MOV  R0, #0
        LDR  R5, [R0]
        MOV  R0, #1
        LDR  R6, [R0]
        MUL  R5, R5, R3
        MUL  R6, R6, R4
        ADD  R7, R5, R6
        MOV  R0, #32
        ADD  R0, R0, R1
        STR  R7, [R0]
        MOV  R0, #63
        MOV  R2, #9
        STR  R2, [R0]
        MOV  R1, #32
        MOV  R4, #1
        LDR  R3, [R1]
        STR  R3, [R0]
        ADD  R1, R1, R4
        LDR  R3, [R1]
        STR  R3, [R0]
        ADD  R1, R1, R4
        LDR  R3, [R1]
        STR  R3, [R0]
        ADD  R1, R1, R4
        LDR  R3, [R1]
        STR  R3, [R0]
        ADD  R1, R1, R4
        LDR  R3, [R1]
        STR  R3, [R0]
        ADD  R1, R1, R4
        LDR  R3, [R1]
        STR  R3, [R0]
        ADD  R1, R1, R4
        LDR  R3, [R1]
        STR  R3, [R0]
        ADD  R1, R1, R4
        LDR  R3, [R1]
        STR  R3, [R0]
        ADD  R1, R1, R4
        LDR  R3, [R1]
        STR  R3, [R0]
        RET
