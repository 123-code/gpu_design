module mini_alu (
    input  logic [7:0] a,
    input  logic [7:0] b,
    input  logic [1:0] op,
    output logic [7:0] y,
    output logic       zero
);
    always_comb begin
        case (op)  // all 4 values covered -> no latch
            2'b00: y = a + b;
            2'b01: y = a - b;
            2'b10: y = a & b;
            2'b11: y = a | b;
        endcase
    end
    assign zero = (y == '0);
endmodule
