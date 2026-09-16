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
//
// NOTE (Jul 3 2026): argmax + bias ROM were dropped in an earlier refactor,
// leaving a bare accumulator that returned the last digit's raw score (FBEST
// read garbage). Restored from commit 1cb2b3e. Port list keeps the 32-bit
// `result` and the (unused) `bias_in` the current core.sv wires up, so no
// core.sv change is needed; best_idx sits in result[7:0] where FBEST reads it.
// ============================================================================
module fc_mac #(
    parameter BIAS_HEX = "/Users/joseignacio/tiny-gpu-fpga/software/mnist_data/bias.hex"
) (
    input  wire        clk,
    input  wire        reset,            // active-high

    input  wire        frst,             // FRST : reset the FC engine
    input  wire        mac_en,           // FMAC : acc += px*wt
    input  wire        farg,             // FARG : finalize current digit
    input  wire        fout,             // FOUT : finalize a HIDDEN neuron
    input  wire [2:0]  out_shift,        // FOUT : extra right shift beyond 8
    input  wire [7:0]  px,               // pixel  (unsigned 0..255)
    input  wire [7:0]  wt,               // weight (signed int8)
    input  wire signed [31:0] bias_in,   // unused: biases come from bias_rom below

    output wire signed [31:0] result,    // FBEST reads result[7:0] = best_idx
    // Raw accumulator, for hidden layers. FARG folds acc into the argmax and
    // clears it, which is all a FINAL classifier layer needs -- but a hidden
    // layer has to read its own dot product back out, requantize it and store
    // it as the next layer's input. FACC Rd,#n reads byte n of this.
    output wire signed [31:0] acc_out,
    // FOUT readback: requantize + ReLU in one step.
    //   clamp( acc >>> (8 + out_shift), 0, 255 )
    // The low clamp IS the ReLU, and the high clamp is the saturation a
    // quantized layer needs. Doing this in software would cost ~10 instructions
    // (the 32-bit acc has to come out a byte at a time, shift amounts must live
    // in registers, and a 6-bit MOV immediate cannot even hold 255).
    output wire [7:0]  relu_out
);
    /* verilator lint_off UNUSED */
    wire signed [31:0] _unused_bias = bias_in;
    /* verilator lint_on UNUSED */

    reg signed [31:0] acc;
    reg signed [31:0] best;
    reg [3:0]         digit;             // digit currently being finalized (0..9)
    reg [3:0]         best_idx;

    // int32 bias ROM (bias.hex: index 0 unused, 1..10 = digit 0..9).
    reg signed [31:0] bias_rom [0:10];
    initial $readmemh(BIAS_HEX, bias_rom);

    // px unsigned (zero-extend), wt signed int8 (sign-extend) -> signed product.
    wire signed [8:0]  px_s = $signed({1'b0, px});
    wire signed [8:0]  wt_s = $signed({wt[7], wt});
    wire signed [31:0] prod = px_s * wt_s;

    // This digit's full score = accumulated dot product + its int32 bias.
    wire signed [31:0] score = acc + bias_rom[digit + 4'd1];

    always @(posedge clk) begin
        if (reset || frst) begin
            acc      <= 32'sd0;
            best     <= 32'sh80000000;   // most negative -> digit 0 always adopts
            digit    <= 4'd0;
            best_idx <= 4'd0;
        end else if (mac_en) begin
            acc <= acc + prod;
        end else if (fout) begin
            acc <= 32'sd0;               // finalize this neuron, ready for the next
        end else if (farg) begin
            if (digit == 4'd0 || score > best) begin
                best     <= score;
                best_idx <= digit;
            end
            digit <= digit + 4'd1;
            acc   <= 32'sd0;             // ready for the next digit's products
        end
    end

    assign result  = {28'd0, best_idx};
    assign acc_out = acc;

    // Arithmetic right shift keeps the sign, so a negative pre-activation stays
    // negative and ReLUs to 0 rather than wrapping to a large positive byte.
    wire signed [31:0] shifted = acc >>> (6'd8 + {3'b000, out_shift});
    assign relu_out = shifted[31]      ? 8'd0      // negative -> ReLU
                    : (|shifted[31:8]) ? 8'd255    // overflow -> saturate
                    :                    shifted[7:0];
endmodule
