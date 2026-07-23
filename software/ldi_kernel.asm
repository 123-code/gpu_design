// LDI proof: build a 16-bit constant > 255 with the new pseudo-op, then emit its
// low and high bytes so the host can confirm BOTH bytes survived. 0x0164 = 356:
//   low  byte = 0x64 = 100
//   high byte = 0x01 = 1
// If LUI/LDI work, the reply is [100][1] per core.
        LDI R3, #356        // R3 = 0x0164  (MOV top4 / LUI mid6 / LUI low6)

        MOV R0, #63         // MMIO TX offset
        STR R3, [R0]        // emit low byte  -> 100

        MOV R2, #8
        SHR R3, R3, R2      // R3 = R3 >> 8 = 0x01
        STR R3, [R0]        // emit high byte -> 1
        RET
