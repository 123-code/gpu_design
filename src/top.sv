`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Tang Nano 20K top-level wrapper for tiny-gpu.
//
// Runs software/kernel.hex once (5 * 3) and shows the result on the 6 LEDs:
//   - while running : all LEDs dark
//   - when finished : LED5 = "done", LED3..0 = result nibble
//     5 * 3 = 15 = 0b001111  ->  LED5 on, LED4 off, LED3..0 on
//
// IMPORTANT — why the GPU runs on a DIVIDED clock, not the full 27 MHz:
//   Static timing passes at 27 MHz, but the worst hold path (the LSU's
//   lsu_state register) has only ~0.4 ns of margin. Real-world clock skew
//   eats that, corrupting lsu_state -> the scheduler hangs in its WAIT state
//   and never reaches DONE (LEDs stay dark). The core only needs to run the
//   kernel once and briefly, so we clock it at ~13 kHz where timing is safe.
//   At that rate the whole program finishes in well under 10 ms (instant to
//   the eye). See diag/ for how this was diagnosed on hardware.
//
// LEDs are active-LOW; the logical pattern is inverted on the way out.
// ============================================================================
module top (
    input  wire       clk,        // 27 MHz crystal  (PIN 4)
    output wire [5:0] led         // 6 onboard LEDs, active-LOW (PIN 15..20)
);
    // NOTE: no button reset. An earlier version gated reset on the S1 button
    // (PIN 88); if that pin doesn't read high when unpressed it pins the GPU
    // in reset forever (dark LEDs). Power-on reset is all we need here.

    // ---- divide 27 MHz -> ~13 kHz GPU clock (div[10] toggles every 1024 cycles) ----
    reg [10:0] div = 11'd0;
    always @(posedge clk) div <= div + 1'b1;
    wire gpu_clk = div[10];

    // ---- power-on reset on the GPU clock ----
    reg [3:0] por = 4'd0;
    wire por_done = &por;
    always @(posedge gpu_clk)
        if (!por_done) por <= por + 1'b1;

    wire reset  = !por_done;   // gpu reset is active-HIGH
    wire enable = por_done;

    // ---- the GPU ----
    wire [7:0] result;
    wire       done;

    gpu uut (
        .clk(gpu_clk),
        .reset(reset),
        .enable(enable),
        .result(result),
        .done(done),
        .debug_core_state(),     // unused at top level
        .debug_instruction()     // unused at top level
    );

    // ---- LED display (active-low) ----
    wire [5:0] led_pattern = done ? {1'b1, result[4:0]} : 6'b000000;
    assign led = ~led_pattern;

endmodule
