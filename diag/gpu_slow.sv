`default_nettype none
`timescale 1ns/1ns

// DIAGNOSTIC: run the GPU on a ~3 Hz clock so we can watch its FSM on the LEDs.
//
//   LED5 = done            (lights and stays when the kernel reaches RET)
//   LED4 = enable          (on after power-on reset releases)
//   LED3 = instr != 0      (ROM is feeding real instructions, not zeros)
//   LED2..0 = core_state    (000 IDLE,001 FETCH,010 DECODE,011 REQ,
//                            100 WAIT,101 EXEC,110 UPDATE,111 DONE)
//
// All active-LOW (inverted at the output).
module top (
    input  wire       clk,        // 27 MHz (PIN 4)
    input  wire       btn_rst_n,  // PIN 88 (unused)
    output wire [5:0] led         // active-LOW (PIN 15..20)
);
    // ---- clock divider: 27 MHz >> 2^22 ~= 3.2 Hz square wave ----
    reg [21:0] div = 22'd0;
    always @(posedge clk) div <= div + 1'b1;
    wire slow = div[21];

    // ---- power-on reset on the slow clock (hold a few slow cycles) ----
    reg [2:0] rstcnt = 3'd0;
    wire reset = (rstcnt != 3'b111);
    always @(posedge slow) if (reset) rstcnt <= rstcnt + 1'b1;
    wire enable = ~reset;

    // ---- the GPU, clocked slowly ----
    wire [7:0]  result;
    wire        done;
    wire [2:0]  cstate;
    wire [15:0] instr;

    gpu uut (
        .clk(slow),
        .reset(reset),
        .enable(enable),
        .result(result),
        .done(done),
        .debug_core_state(cstate),
        .debug_instruction(instr)
    );

    wire instr_nonzero = |instr;

    assign led = ~{done, enable, instr_nonzero, cstate};
endmodule
