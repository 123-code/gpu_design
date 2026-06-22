// Branch-divergence validation kernel.
//
// Each lane branches on its OWN threadIdx, so the 4 lanes of a warp must take
// different paths in lockstep:
//   threadIdx < 2  (lanes 0,1) -> take the branch     -> R3 = 10
//   threadIdx >= 2 (lanes 2,3) -> fall through (stay)  -> R3 = 20
//
// Correct SIMT divergence => R3 = [10, 10, 20, 20] across lanes 0..3.
// If divergence were broken (all lanes follow lane 0), every lane would take
// lane 0's branch and R3 would be [10, 10, 10, 10].
//
// Mechanism: BRn pushes the "stay" lanes onto the reconvergence stack and runs
// the "branch" lanes first at iftrue; SYNC pops to run the stay lanes.
        TID  R1            // R1 = threadIdx (per-lane: 0,1,2,3)
        MOV  R2, #2
        CMP  R1, R2        // N flag set where R1 < 2  (lanes 0,1)
        BRn  iftrue        // branch lanes -> iftrue; stay lanes pushed
        MOV  R3, #20       // STAY path (lanes 2,3) — runs 2nd via SYNC pop
        RET
iftrue: MOV  R3, #10       // BRANCH path (lanes 0,1) — runs 1st
        SYNC               // reconverge: pop -> run the stay path
