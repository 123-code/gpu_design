`default_nettype none
`timescale 1ns/1ns

// DIAGNOSTIC ONLY: prove the clock, LED pins, and active-low polarity work.
// Free-running counter off the 27 MHz clock; the top counter bits drive the
// LEDs so they visibly count in binary (~0.4 Hz on the slowest bit).
// If these LEDs move, the clock and LED path are good.
module top (
    input  wire       clk,        // 27 MHz (PIN 4)
    input  wire       btn_rst_n,  // unused here (PIN 88)
    output wire [5:0] led         // active-LOW (PIN 15..20)
);
    reg [25:0] cnt = 26'd0;
    always @(posedge clk) cnt <= cnt + 1'b1;

    // active-low: invert so a '1' bit lights the LED
    assign led = ~cnt[25:20];
endmodule
