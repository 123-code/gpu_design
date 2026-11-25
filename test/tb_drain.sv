`default_nettype none
`timescale 1ns/1ns

// A block is not done until its posted stores have drained.
// software/drain_kernel.asm: 8 short blocks over the 2 cores, each ending on
// an STG. Every one of the 32 stores must be in SDRAM afterwards: a block
// that retires with a store still in its L1 write buffer would lose it to
// the next block's reset.
module tb;
    localparam BIT_CYCLES = 16;
    localparam GRID = 8;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;
    wire sd_clk, sd_cke, sd_cs_n, sd_cas_n, sd_ras_n, sd_we_n;
    wire [3:0] sd_dqm; wire [10:0] sd_addr; wire [1:0] sd_ba; wire [31:0] sd_dq;

    top #(.CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1), .BLOCK_DIM(4), .SDRAM_INIT_CYCLES(200),
         .SDRAM_REF_CYCLES(12)) dut (    // refresh nearly back to back: stores queue behind it
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

    integer i, b, t, fails, a;
    reg [31:0] w;
    reg [15:0] got;
    initial begin
        for (i = 0; i < 256; i = i + 1) host_prog[i] = 16'hxxxx;
        $readmemh("software/drain_kernel.hex", host_prog);
        repeat (300) @(posedge clk);                  // SDRAM init
        send_frame(prog_len(256), 0, GRID);
        @(posedge dut.done);
        repeat (200) @(posedge clk);

        fails = 0;
        for (b = 0; b < GRID; b = b + 1)
            for (t = 0; t < 4; t = t + 1) begin
                a = 512 + 8*b + 2*t;
                w = chip.mem[a >> 2];
                got = a[1] ? w[31:16] : w[15:0];
                if (got !== 16*b + t + 1) begin
                    if (fails < 8) $display("  block %0d lane %0d: global[%0d] = %0d, want %0d", b, t, a, got, 16*b + t + 1);
                    fails = fails + 1;
                end
            end
        if (fails == 0)
            $display("RESULT: PASS - all %0d posted stores landed, %0d blocks ending on an STG", 4*GRID, GRID);
        else
            $display("RESULT: FAIL - %0d of %0d posted stores lost", fails, 4*GRID);
        $finish;
    end
    initial begin
        repeat (2000000) @(posedge clk);
        $display("RESULT: FAIL - timeout");
        $finish;
    end
endmodule
