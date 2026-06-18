`default_nettype none
`timescale 1ns/1ns

// Hands one block to each core at the start of a run and reports when every
// dispatched core has finished.
//
// The cores are one-shot per run: the scheduler's DONE state is terminal
// (only a GPU reset returns it to IDLE), and top.sv pulses gpu_reset before
// each run. So there is no re-dispatch loop here — TOTAL_BLOCKS must be
// <= the number of cores (2). done is a level: it rises once the last core
// finishes and stays high until the next run's reset (the DMA re-arms on its
// rising edge).
module dispatcher #(
    parameter TOTAL_BLOCKS = 2   // 1 = core 0 only, 2 = both cores
) (
    input wire clk,
    input wire reset,
    input wire enable,

    input wire core_0_done, // sticky level from core 0's scheduler
    input wire core_1_done, // sticky level from core 1's scheduler

    output reg core_0_start,    // 1-cycle start pulse to core 0
    output reg [7:0] core_0_id, // block ID handed to core 0

    output reg core_1_start,    // 1-cycle start pulse to core 1
    output reg [7:0] core_1_id, // block ID handed to core 1

    output wire done            // all dispatched blocks finished
);

    reg dispatched; // blocks for this run have been handed out

    always @(posedge clk) begin
        if (reset) begin
            dispatched   <= 1'b0;
            core_0_start <= 1'b0;
            core_1_start <= 1'b0;
            core_0_id    <= 8'd0;
            core_1_id    <= 8'd0;
        end else if (enable) begin
            core_0_start <= 1'b0;
            core_1_start <= 1'b0;

            if (!dispatched) begin
                core_0_start <= 1'b1;
                core_0_id    <= 8'd0;
                if (TOTAL_BLOCKS > 1) begin
                    core_1_start <= 1'b1;
                    core_1_id    <= 8'd1;
                end
                dispatched <= 1'b1;
            end
        end
    end

    assign done = dispatched && core_0_done
                  && (TOTAL_BLOCKS < 2 || core_1_done);

endmodule
