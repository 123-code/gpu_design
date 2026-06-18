`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Fully-connected MAC + argmax coprocessor.
//
// The 8-bit datapath cannot accumulate or rank FC digit scores: each score is a
// sum of 169 signed products (pixel x weight) plus a 32-bit bias, reaching far
// beyond 8 bits. This unit owns a wide (32-bit signed) accumulator AND the
// argmax, exactly mirroring cnn_chip's fc_layer.v. Four ops decode under opcode
// 0000 (sub-function in instruction[5:4]):
//
//   FRST        acc<-0, digit<-0, best<- -inf, best_idx<-0   (start of FC pass)
//   FMAC rs,rt  acc <- acc + (unsigned pixel rs) * (signed weight rt)
//   FARG        score = acc + bias[digit]; if score>best -> best,best_idx=digit;
//               then digit++ and acc<-0   (finalize one digit, like fc_layer)
//   FRD/FBEST rd rd <- best_idx (the predicted digit)
//
// Biases are int32, held in a small ROM loaded from bias.hex (idx 1..10 = digits
// 0..9, matching cnn_chip). argmax runs in the full 32-bit domain -- no lossy
// requantization -- so tiny-gpu reproduces cnn_chip's predictions bit-for-bit.
// The 9x8 product maps to a DSP block.
// ============================================================================
module fc_mac #(

) (
    input  wire        clk,
    input  wire        reset,            // active-high

    input  wire        frst,             // FRST : reset the FC engine
    input  wire        mac_en,           // FMAC : acc += px*wt
    input  wire        farg,             // FARG : finalize current digit
    input  wire [7:0]  px,               // pixel  (unsigned 0..255)
    input  wire [7:0]  wt,               // weight (signed int8)
    input  wire signed [31:0] bias_in,   // receiving the bias 

    output wire signed [31:0] result
);
    reg signed [31:0] acc;
    reg signed [31:0] final_score; // Holds the final answer so software can read it safely

    // int32 bias ROM (bias.hex: index 0 unused, 1..10 = digit 0..9).


    // px unsigned (zero-extend), wt signed int8 (sign-extend) -> signed product.
    wire signed [8:0]  px_s = $signed({1'b0, px});
    wire signed [8:0]  wt_s = $signed({wt[7], wt});
    wire signed [31:0] prod = px_s * wt_s;

    // This digit's full score = accumulated dot product + bias.
    wire signed [31:0] score = acc + bias_in;

    always @(posedge clk) begin
        if (reset || frst) begin
            acc         <= 32'sd0;
            final_score <= 32'sd0;
        end else if (mac_en) begin
            acc <= acc + prod;
        end else if (farg) begin
            final_score <= score;        // Latch the final score (acc + bias)
            acc         <= 32'sd0;       // Reset acc for the next calculation
        end
    end

    assign result = final_score;
endmodule
