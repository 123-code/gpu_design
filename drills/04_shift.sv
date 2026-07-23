// DRILL 04 — shift register (~5 lines)
//
// 8-bit serial-in, parallel-out. On each clock edge with en=1, shift left:
// every bit moves up one position and `din` enters bit 0.
// rst is synchronous, active high; clears to 0.
//
// The drill: concatenation `{ }` — one line replaces eight.
// (This is exactly what your uart_tx does with its shift-out register.)
//
// Run:  make drill D=04_shift

module shift_reg (
    input  logic       clk,
    input  logic       rst,
    input  logic       en,
    input  logic       din,
    output logic [7:0] q
);

    // TODO: one always_ff, one concatenation

endmodule
