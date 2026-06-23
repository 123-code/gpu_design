// mac_read32 — prove the FULL 32-bit MAC result can be read out as 4 bytes.
//
// The MAC unit accumulates in 32 bits but the register file is 8-bit, so the
// result used to be truncated to its low byte. MAC Rd,#n now writes byte n
// (0=LSB..3=MSB) of the 32-bit result, so software pulls the whole value out
// in four reads and emits it little-endian.
//
// MACL Rs pushes one operand pair into the MAC buffer: pixel = Rs, weight = R0.
// Here weight = 20, pixel = 30, 8 pushes -> sum = 8 * 30 * 20 = 4800 = 0x12C0.
//   byte0 = 0xC0 (192)   byte1 = 0x12 (18)   byte2 = 0   byte3 = 0
// Reassembled = 4800, a value the old low-byte-only path (0xC0 = 192) could
// never report.

        MOV  R0, #20        // weight (rt source for MACL)
        MOV  R1, #30        // pixel  (rs source for MACL)

        MACL R1
        MACL R1
        MACL R1
        MACL R1
        MACL R1
        MACL R1
        MACL R1
        MACL R1

        // --- read the 32-bit result into four 8-bit registers ---
        MAC  R4, #0         // R4 = result[7:0]   = 0xC0
        MAC  R5, #1         // R5 = result[15:8]  = 0x12
        MAC  R6, #2         // R6 = result[23:16] = 0x00
        MAC  R7, #3         // R7 = result[31:24] = 0x00

        // --- emit [len=4][b0][b1][b2][b3] (little-endian) ---
        MOV  R2, #63        // MMIO UART TX offset
        MOV  R3, #4         // frame length = 4 result bytes
        STR  R3, [R2]       // length
        STR  R4, [R2]       // b0
        STR  R5, [R2]       // b1
        STR  R6, [R2]       // b2
        STR  R7, [R2]       // b3
        RET
