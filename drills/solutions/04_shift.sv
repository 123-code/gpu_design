module shift_reg (
    input  logic       clk,
    input  logic       rst,
    input  logic       en,
    input  logic       din,
    output logic [7:0] q
);
    always_ff @(posedge clk) begin
        if (rst)     q <= '0;
        else if (en) q <= {q[6:0], din};
    end
endmodule
