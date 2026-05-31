// CONV KERNEL — exercise the 3x3 MAC instruction.
// Loads 9 pixels (=30) then 9 weights (=20) into the MAC buffer, fires the MAC.
//   sum = 9 * 30 * 20 = 5400 ; quantize: 5400 >> 8 = 21  ->  R3 = 21
//
// MACL Rs pushes Rs into the MAC operand buffer (pixels first, then weights).
// MAC  Rd writes the MAC result into Rd.

// --- 9 pixels = 30 ---
MOV  R5, #30
MACL R5
MACL R5
MACL R5
MACL R5
MACL R5
MACL R5
MACL R5
MACL R5
MACL R5

// --- 9 weights = 20 ---
MOV  R5, #20
MACL R5
MACL R5
MACL R5
MACL R5
MACL R5
MACL R5
MACL R5
MACL R5
MACL R5

// --- fire the MAC, capture result, halt ---
MAC  R3
RET
