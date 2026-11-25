`default_nettype none
`timescale 1ns/1ns

// Grid scheduling, end to end through the UART (software/grid_kernel.asm).
//
// Launches gridDim = 9 blocks on the 2 cores. Low blocks are deliberately the
// slow ones, so one core sits on block 0 while the other drains later blocks,
// some of which finish before block 0 does. Checks:
//   - every emitting block's [bid][val] arrives, val = 7*bid + gridDim
//   - the reply is in blockIdx order even though blocks finished out of order
//   - both cores ran blocks (the work was actually spread), and the
//     dispatcher issued all 9 blocks exactly once
//   - done rises after the last block
module tb;
    localparam BIT_CYCLES = 16;
    localparam GRID = 9;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(.CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1)) dut (
        .clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led)
    );
    always #5 clk = ~clk;

    `include "test/host_uart.svh"

    // Which core ran which block (sampled on the dispatcher's start pulses)
    integer starts_0 = 0, starts_1 = 0;
    reg [GRID-1:0] issued = 0;
    reg dup = 0;
    always @(posedge clk) begin
        if (dut.uut.core_0_start) begin
            starts_0 = starts_0 + 1;
            if (issued[dut.uut.core_0_id]) dup = 1;
            issued[dut.uut.core_0_id] = 1'b1;
        end
        if (dut.uut.core_1_start) begin
            starts_1 = starts_1 + 1;
            if (issued[dut.uut.core_1_id]) dup = 1;
            issued[dut.uut.core_1_id] = 1'b1;
        end
    end

    integer i, b, fails, n;
    reg [7:0] got_bid, got_val;
    initial begin
        $readmemh("software/grid_kernel.hex", host_prog);
        repeat (64) @(posedge clk);
        send_frame(prog_len(256), 0, GRID);

        fails = 0; n = 0;
        for (b = 0; b < GRID; b = b + 1) begin
            if (b % 3 != 1) begin
                uart_recv(got_bid); uart_recv(got_val);
                n = n + 1;
                if (got_bid !== b[7:0] || got_val !== (7*b + GRID)) begin
                    fails = fails + 1;
                    $display("  frame %0d: got [%0d][%0d], expected [%0d][%0d]",
                             n, got_bid, got_val, b, 7*b + GRID);
                end
            end
        end
        // the last block's other warp may still be finishing (a warp stalls
        // the core while its emit drains), so give done a bounded wait
        for (i = 0; i < 20000 && dut.done !== 1'b1; i = i + 1) @(posedge clk);

        $display("blocks run: core0=%0d core1=%0d, done=%0b", starts_0, starts_1, dut.done);
        if (starts_0 + starts_1 != GRID || issued != {GRID{1'b1}} || dup) begin
            fails = fails + 1; $display("  dispatcher did not issue each block exactly once");
        end
        if (starts_0 == 0 || starts_1 == 0) begin
            fails = fails + 1; $display("  one core never got work");
        end
        if (dut.done !== 1'b1) begin
            fails = fails + 1; $display("  done never rose");
        end

        if (fails == 0)
            $display("RESULT: PASS - %0d blocks over 2 cores (%0d/%0d), reply in blockIdx order",
                     GRID, starts_0, starts_1);
        else
            $display("RESULT: FAIL - %0d mismatch(es)", fails);
        $finish;
    end

    initial begin
        repeat (3000000) @(posedge clk);
        $display("RESULT: FAIL - timeout");
        $finish;
    end
endmodule
