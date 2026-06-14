; tid_demo: each of the 4 SIMT lanes copies its own threadIdx into R1.
; Before TID existed, the 4 lanes were unable to read R15 (%threadIdx), so they
; all held identical values. With TID, R1 = 0,1,2,3 across the 4 lanes — the
; first real per-thread divergence on this GPU.
TID R1
RET
