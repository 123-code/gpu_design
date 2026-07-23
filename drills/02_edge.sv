// DRILL 02 — rising-edge detector (~6 lines)
//
// Watch input `sig`. When a clock edge samples sig=1 and the PREVIOUS sample
// was 0, drive `pulse` high for exactly one cycle (registered output: pulse
// goes high on the edge that saw the rise, low on the next edge).
// rst is synchronous, active high; clears everything.
//
// This is the "how do I remember last cycle's value" drill — the core trick
// behind every handshake and your own DMA re-arm rising-edge fix.
//
// Run:  make drill D=02_edge

module edge_detect (
    input  logic clk,
    input  logic rst,
    input  logic sig,
    output logic pulse
);

    // TODO: register the previous sample of sig, compare, register the output

endmodule
