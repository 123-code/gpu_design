`default_nettype none
`timescale 1ns/1ns

// Global memory end to end: SDRAM controller + checking SDRAM model, per-core
// L1, LDG/STG, and TMAG (copy engine from global memory).
//
// software/gen_global_test.py writes the kernel, a payload that the DMA puts
// in GLOBAL memory, and the bytes the grid must leave there. 4 blocks run on
// the 2 cores and all write into the one SDRAM. Checks:
//   - the result region of global memory matches the reference byte for byte
//   - both cores' L1s served hits (the second LDG of each line)
//   - the SDRAM model saw no protocol violation
module tb;
    localparam BIT_CYCLES = 16;
    localparam GRID = 4;
    localparam EXPECT_BASE = 512, EXPECT_LEN = 1024;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    wire sd_clk, sd_cke, sd_cs_n, sd_cas_n, sd_ras_n, sd_we_n;
    wire [3:0] sd_dqm; wire [10:0] sd_addr; wire [1:0] sd_ba; wire [31:0] sd_dq;

    top #(.CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1), .BLOCK_DIM(4), .SDRAM_INIT_CYCLES(200)) dut (
        .clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led),
        .O_sdram_clk(sd_clk), .O_sdram_cke(sd_cke), .O_sdram_cs_n(sd_cs_n),
        .O_sdram_cas_n(sd_cas_n), .O_sdram_ras_n(sd_ras_n), .O_sdram_wen_n(sd_we_n),
        .O_sdram_dqm(sd_dqm), .O_sdram_addr(sd_addr), .O_sdram_ba(sd_ba), .IO_sdram_dq(sd_dq)
    );
    sdram_model chip (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .ba(sd_ba), .addr(sd_addr), .dqm(sd_dqm), .dq(sd_dq)
    );
    always #5 clk = ~clk;

    `include "test/host_uart.svh"

    reg [7:0] expect_b [0:EXPECT_LEN-1];
    integer i, fails, ndata, hits0, hits1;
    reg [7:0] got;
    reg [31:0] w;

    // L1 hit counters reset with each block; accumulate them across blocks
    integer h0 = 0, h1 = 0;
    reg [15:0] last0 = 0, last1 = 0;
    always @(posedge clk) begin
        if (dut.uut.compute_core_0.l1_hits > last0) h0 = h0 + (dut.uut.compute_core_0.l1_hits - last0);
        if (dut.uut.compute_core_1.l1_hits > last1) h1 = h1 + (dut.uut.compute_core_1.l1_hits - last1);
        last0 = dut.uut.compute_core_0.l1_hits;
        last1 = dut.uut.compute_core_1.l1_hits;
    end

    initial begin
        for (i = 0; i < 256; i = i + 1) host_prog[i] = 16'hxxxx;
        for (i = 0; i < 8192; i = i + 1) host_data[i] = 8'hxx;
        $readmemh("software/build/global.hex", host_prog);
        $readmemh("software/build/global.data.hex", host_data);
        $readmemh("software/build/global.expect.hex", expect_b);
        ndata = 0;
        while (ndata < 8192 && ^host_data[ndata] !== 1'bx) ndata = ndata + 1;

        repeat (64) @(posedge clk);
        send_frame_ex(prog_len(256), ndata, GRID, 1);
        @(posedge dut.done);
        repeat (50) @(posedge clk);

        fails = 0;
        for (i = 0; i < EXPECT_LEN; i = i + 1) begin
            w = chip.mem[(EXPECT_BASE + i) >> 2];
            got = w[8*((EXPECT_BASE + i) % 4) +: 8];
            if (got !== expect_b[i]) begin
                if (fails < 12) $display("  global[%0d]: got %02x, want %02x", EXPECT_BASE + i, got, expect_b[i]);
                fails = fails + 1;
            end
        end
        $display("L1 hits: core0 %0d, core1 %0d; SDRAM: %0d reads, %0d writes, %0d refreshes, %0d violations",
                 h0, h1, chip.reads, chip.writes, chip.refreshes, chip.violations);
        if (h0 == 0 || h1 == 0) begin fails = fails + 1; $display("  an L1 never hit"); end
        if (chip.violations != 0) fails = fails + 1;

        if (fails == 0)
            $display("RESULT: PASS - %0d blocks: LDG/STG through the L1 and TMAG->MMA results all landed in SDRAM", GRID);
        else
            $display("RESULT: FAIL - %0d problem(s)", fails);
        $finish;
    end

    initial begin
        repeat (4000000) @(posedge clk);
        $display("RESULT: FAIL - timeout");
        $finish;
    end
endmodule
