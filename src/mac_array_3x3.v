// 9-MAC adder tree + ReLU + quantize for the parallel 3x3 conv.
// Pipeline: products -> adder tree (combinational) -> emit (1 cycle).
// Total latency from valid_in to valid_out: 2 cycles.
//
// Matches conv_serial.v's quantize semantics exactly:
//   if (sum <  0)               -> 0
//   if ((sum >>> 8) > 255)      -> 255
//   else                        -> sum[15:8]
//
// No bias add here. Conv has no bias in this design (training enforces
// bias=False on nn.Conv2d) -- bias_in belongs to the FC layer only.

module mac_array_3x3 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,

    input  wire [7:0]        px00, px01, px02,
    input  wire [7:0]        px10, px11, px12,
    input  wire [7:0]        px20, px21, px22,

    input  wire signed [7:0] w00, w01, w02,
    input  wire signed [7:0] w10, w11, w12,
    input  wire signed [7:0] w20, w21, w22,

    output reg  [7:0]        pixel_out,
    output reg               valid_out
);

    // Stage 1: latch 9 signed products + carry valid forward.
    reg signed [15:0] p0, p1, p2, p3, p4, p5, p6, p7, p8;
    reg               valid_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p0 <= 0; p1 <= 0; p2 <= 0; p3 <= 0;
            p4 <= 0; p5 <= 0; p6 <= 0; p7 <= 0; p8 <= 0;
            valid_s1 <= 1'b0;
        end else begin
            // Zero-extend unsigned pixel to 9-bit signed so the product is
            // strictly (pixel x signed_weight) without sign-extension surprises.
            p0 <= $signed({1'b0, px00}) * w00;
            p1 <= $signed({1'b0, px01}) * w01;
            p2 <= $signed({1'b0, px02}) * w02;
            p3 <= $signed({1'b0, px10}) * w10;
            p4 <= $signed({1'b0, px11}) * w11;
            p5 <= $signed({1'b0, px12}) * w12;
            p6 <= $signed({1'b0, px20}) * w20;
            p7 <= $signed({1'b0, px21}) * w21;
            p8 <= $signed({1'b0, px22}) * w22;
            valid_s1 <= valid_in;
        end
    end

    // Stage 2: combinational adder tree -> sequential emit.
    // Sign-extend each 16-bit product to 32-bit signed before summing so the
    // worst-case sum (9 * 127 * 255 = ~291k) fits without wrap.
    wire signed [31:0] sum =
        {{16{p0[15]}}, p0} + {{16{p1[15]}}, p1} +
        {{16{p2[15]}}, p2} + {{16{p3[15]}}, p3} +
        {{16{p4[15]}}, p4} + {{16{p5[15]}}, p5} +
        {{16{p6[15]}}, p6} + {{16{p7[15]}}, p7} +
        {{16{p8[15]}}, p8};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_out <= 8'd0;
            valid_out <= 1'b0;
        end else begin
            if (sum < 32'sd0)
                pixel_out <= 8'd0;
            else if ((sum >>> 8) > 32'sd255)
                pixel_out <= 8'd255;
            else
                pixel_out <= sum[15:8];
            valid_out <= valid_s1;
        end
    end

endmodule
