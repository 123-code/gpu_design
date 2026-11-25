// Two-board all-reduce, phase 1 (test/tb_link.sv): every element goes to the
// OTHER board. Grid of 2 blocks x 4 lanes, element i = 4*blockIdx + tid:
// x = global[2i] (this board's vector); store x to global 0x8000 | (256 + 2i)
// -- bit 15 sends it over the board link into the peer's SDRAM at 256 + 2i.
        TID  R1
        BID  R2
        ADD  R3, R2, R2
        ADD  R3, R3, R3
        ADD  R3, R3, R1
        ADD  R3, R3, R3      // 2i
        LDG  R4, [R3]
        LDI  R5, #33024      // 0x8100: the peer board, offset 256
        ADD  R5, R5, R3
        STG  R4, [R5]        // remote store
        RET
