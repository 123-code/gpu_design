`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Fully-connected MAC coprocessor.
//
// The 8-bit datapath cannot accumulate an FC digit score: each score is a sum
// of up to 169 signed products (pixel x weight), reaching ~24 bits. This unit
// holds a wide (32-bit signed) accumulator and exposes three core ops, decoded
// under opcode 0000 (mirrors the 3x3 conv MAC coprocessor pattern):
//
//   FCLR        acc <- 0
//   FMAC rs,rt  acc <- acc + (unsigned pixel rs) * (signed weight rt)
//   FRD  rd     rd  <- saturate8( acc >>> Q )   (requantize back to 8-bit)
//
// Q is the requantization shift; offline weight quantization picks a scale so
// typical scores land in the int8 range, keeping software argmax meaningful.
// The 9x8 multiply maps to a DSP block (plenty free at ~25% DSP usage).
// ============================================================================
module fc_mac #(
    parameter Q = 6                      // requantization right-shift for FRD
) (
    input  wire        clk,
    input  wire        reset,            // active-high

    input  wire        clear,            // FCLR  : acc <- 0          (1-cycle)
    input  wire        mac_en,           // FMAC  : acc += px*wt       (1-cycle)
    input  wire [7:0]  px,               // pixel  (unsigned 0..255)
    input  wire [7:0]  wt,               // weight (signed int8)

    output wire [7:0]  result            // FRD readout: sat(acc >>> Q) as int8
);
    reg signed [31:0] acc;

    // px is unsigned (zero-extend to 9-bit signed), wt is signed int8.
    wire signed [8:0] px_s = $signed({1'b0, px});
    wire signed [8:0] wt_s = $signed({wt[7], wt});   // sign-extend to 9 bits
    wire signed [31:0] prod = px_s * wt_s;

    always @(posedge clk) begin
        if (reset || clear) acc <= 32'sd0;
        else if (mac_en)    acc <= acc + prod;
    end

    // Arithmetic shift, then saturate to signed 8-bit [-128, 127].
    wire signed [31:0] shifted = acc >>> Q;
    assign result = (shifted >  32'sd127)  ? 8'sd127 :
                    (shifted < -32'sd128)  ? -8'sd128 :
                                             shifted[7:0];
endmodule
