`default_nettype none
`timescale 1ns/1ns

// Issue rate: cycles per instruction for compute-only code, one warp and two.
// Runs software/cpi_kernel.asm (a 4-instruction ALU/branch loop) and counts
// core 0's DECODE entries (one per instruction issued) and its busy cycles.
// The overlapped issue path (fetch during writeback, operands read in
// DECODE) takes 3 cycles per compute instruction; the test fails above 3.2,
// so a change that quietly lengthens the issue loop shows up here. It also
// checks the loop's result (R4 = 1 + 2 + ... + 50 = 1275) in every lane.
module tb;
    localparam BIT_CYCLES = 16;
    parameter BD = 4;                     // 4 = one warp, 8 = two warps

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(.CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1), .BLOCK_DIM(BD)) dut (
        .clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led)
    );
    always #5 clk = ~clk;

    `include "test/host_uart.svh"

    integer instrs = 0, cycles = 0;
    reg [3:0] st_d = 0;
    always @(posedge clk) begin
        if (dut.uut.core_0_busy && !dut.uut.core_0_done) begin
            cycles = cycles + 1;
            // an instruction issues through DECODE, or straight from the
            // pipeline in RUN (run_adv)
            if (dut.uut.compute_core_0.core_state == 4'b0011) instrs = instrs + 1;
            if (dut.uut.compute_core_0.core_scheduler.run_adv) instrs = instrs + 1;
        end
    end

    integer fails, cpi100, w, l;
    initial begin
        for (w = 0; w < 256; w = w + 1) host_prog[w] = 16'hxxxx;
        $readmemh("software/cpi_kernel.hex", host_prog);
        repeat (64) @(posedge clk);
        send_frame(prog_len(256), 0, 0);
        @(posedge dut.done);
        repeat (10) @(posedge clk);

        fails = 0;
        `define R4(W, L) dut.uut.compute_core_0.warp_block[W].thread_block[L].thread_regs.registers[4]
        if (`R4(0,0) !== 16'd1275 || `R4(0,1) !== 16'd1275 || `R4(0,2) !== 16'd1275 || `R4(0,3) !== 16'd1275)
            fails = fails + 1;
        if (BD == 8 && (`R4(1,0) !== 16'd1275 || `R4(1,1) !== 16'd1275 || `R4(1,2) !== 16'd1275 || `R4(1,3) !== 16'd1275))
            fails = fails + 1;
        cpi100 = (100 * cycles) / instrs;
        $display("%0d warp(s): %0d instructions in %0d cycles = %0d.%02d cycles/instruction",
                 BD/4, instrs, cycles, cpi100 / 100, cpi100 % 100);
        if (cpi100 > 200) begin fails = fails + 1; $display("  issue loop slower than 2.0 cycles/instr"); end
        if (fails == 0)
            $display("RESULT: PASS - %0d warp(s): %0d.%02d cycles/instruction, loop result right in every lane",
                     BD/4, cpi100 / 100, cpi100 % 100);
        else
            $display("RESULT: FAIL - %0d problem(s)", fails);
        $finish;
    end

    initial begin
        repeat (2000000) @(posedge clk);
        $display("RESULT: FAIL - timeout");
        $finish;
    end
endmodule
