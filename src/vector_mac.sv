`default_nettype none
`timescale 1ns/1ns

module vector_mac (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,

    // 8 flat pixel inputs (unsigned 0-255)
    input  wire [7:0]        px0, px1, px2, px3, px4, px5, px6, px7,

    // 8 flat weight inputs (signed -128 to 127)
    input  wire signed [7:0] w0, w1, w2, w3, w4, w5, w6, w7,

    output reg signed [31:0] result_out,
    output reg               valid_out
);

    // Stage 1: latch 8 signed products + carry valid forward.
    reg signed [15:0] p0, p1, p2, p3, p4, p5, p6, p7;
    reg               valid_s1;

    // Synchronous reset (was async `negedge rst_n`): the async CLEAR pin on these
    // wide product regs put the high-fanout reset net on the critical path. A
    // synchronous reset is sampled like ordinary data, freeing that path.
    always @(posedge clk) begin
        if (!rst_n) begin
            p0 <= 0; p1 <= 0; p2 <= 0; p3 <= 0;
            p4 <= 0; p5 <= 0; p6 <= 0; p7 <= 0;
            valid_s1 <= 1'b0;
        end else begin
            // Zero-extend unsigned pixel to 9-bit signed so the product is
            // strictly (pixel x signed_weight) without sign-extension surprises.
            p0 <= $signed({1'b0, px0}) * w0;
            p1 <= $signed({1'b0, px1}) * w1;
            p2 <= $signed({1'b0, px2}) * w2;
            p3 <= $signed({1'b0, px3}) * w3;
            p4 <= $signed({1'b0, px4}) * w4;
            p5 <= $signed({1'b0, px5}) * w5;
            p6 <= $signed({1'b0, px6}) * w6;
            p7 <= $signed({1'b0, px7}) * w7;
            valid_s1 <= valid_in;
        end
    end

    // Stage 2: combinational adder tree -> sequential emit.
    // Sign-extend each 16-bit product to 32-bit signed before summing.
    wire signed [31:0] sum =
        {{16{p0[15]}}, p0} + {{16{p1[15]}}, p1} +
        {{16{p2[15]}}, p2} + {{16{p3[15]}}, p3} +
        {{16{p4[15]}}, p4} + {{16{p5[15]}}, p5} +
        {{16{p6[15]}}, p6} + {{16{p7[15]}}, p7};

    always @(posedge clk) begin   // synchronous reset (see Stage 1 note)
        if (!rst_n) begin
            result_out <= 32'sd0;
            valid_out <= 1'b0;
        end else begin
            // Raw 32-bit output. No ReLU, no quantization. 
            // Software is now responsible for clipping and shifting.
            result_out <= sum;
            valid_out <= valid_s1;
        end
    end

endmodule
