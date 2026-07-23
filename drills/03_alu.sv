// DRILL 03 — combinational mini-ALU (~10 lines)
//
// Pure combinational logic: no clock, no reset, no state.
//   op = 2'b00 -> y = a + b
//   op = 2'b01 -> y = a - b
//   op = 2'b10 -> y = a & b
//   op = 2'b11 -> y = a | b
//   zero = 1 when y == 0
//
// The drill: always_comb + case, and the rule that every path must assign y
// (a missed path infers a latch — a classic interview question).
//
// Run:  make drill D=03_alu

module mini_alu (
    input  logic [7:0] a,
    input  logic [7:0] b,
    input  logic [1:0] op,
    output logic [7:0] y,
    output logic       zero
);

    // TODO: one always_comb with a case, plus the zero flag
    always_comb begin
        case (op)
            2'b00: y = a + b;
            2'b01: y = a - b;
            2'b10: y = a & b;
            2'b11: y = a | b;
            default: y = 8'b0;  
        endcase
        zero = (y == 0);
    end

endmodule
