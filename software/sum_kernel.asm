// General-purpose proof: load a program + data over UART, run it, read the
// result back — no reflash. Sums the first 4 data bytes (mem[0..3]) and emits
// the framed result [len=1][sum].
//
// Reply framing convention: a kernel emits a 1-byte length, then that many
// result bytes, so the host knows when this core's output ends. Both cores run
// this same kernel over the same data (broadcast), so the host sees the frame
// twice: [1][sum][1][sum].
        MOV R3, #0          // R3 = running sum

        MOV R0, #0
        LDR R1, [R0]        // R1 = mem[0]
        ADD R3, R3, R1

        MOV R0, #1
        LDR R1, [R0]        // R1 = mem[1]
        ADD R3, R3, R1

        MOV R0, #2
        LDR R1, [R0]        // R1 = mem[2]
        ADD R3, R3, R1

        MOV R0, #3
        LDR R1, [R0]        // R1 = mem[3]
        ADD R3, R3, R1

        // ---- emit [len=1][sum] ----
        MOV R0, #63         // R0 = MMIO TX offset
        MOV R2, #1          // length = 1 result byte
        STR R2, [R0]        // emit length
        STR R3, [R0]        // emit sum
        RET
