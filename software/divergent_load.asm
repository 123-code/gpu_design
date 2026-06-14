; divergent_load: each lane loads a DIFFERENT memory element using its threadIdx.
;   R1 = threadIdx              (per-lane: 0,1,2,3)
;   R2 = mem[rbase + R1]        (LDR addr = read base(0) + threadIdx)
; With mem[0..3] preloaded to 4 distinct bytes (streamed in by the DMA), the 4
; lanes diverge: R2 differs per lane, served by the lsu_arbiter's 4 distinct reads.
TID R1
LDR R2, [R1]
RET
