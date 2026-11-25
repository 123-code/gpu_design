`default_nettype none
`timescale 1ns/1ns

// On-chip host CPU drives the GPU with no PC involved (software/fw/host.c).
// Nothing is sent over the UART INTO the board: the RV32I core loads the GPU
// kernel, writes inputs to global memory, launches a 2-block grid, waits,
// reads the results back from global memory, checks them itself, and
// reports them over the UART: 8 result bytes, then 'P' or 'F'. The bench
// checks those bytes against its own computation AND the SDRAM contents.
module tb;
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;
    wire sd_clk, sd_cke, sd_cs_n, sd_cas_n, sd_ras_n, sd_we_n;
    wire [3:0] sd_dqm; wire [10:0] sd_addr; wire [1:0] sd_ba; wire [31:0] sd_dq;

    top #(.CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1), .BLOCK_DIM(4), .SDRAM_INIT_CYCLES(200),
          .HOST_CPU(1), .FIRMWARE("software/build/fw.hex")) dut (
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

    function automatic [15:0] y(input integer i);
        reg [15:0] x;
        begin x = 37*i + 5; y = x*x + (i / 4); end
    endfunction

    integer i, fails, a;
    reg [7:0] b;
    reg [31:0] w;
    reg [15:0] g;
    initial begin
        fails = 0;
        for (i = 0; i < 8; i = i + 1) begin
            uart_recv(b);
            if (b !== (y(i) & 8'hff)) begin
                fails = fails + 1; $display("  result %0d: UART %02x, want %02x", i, b, y(i) & 8'hff);
            end
            a = 64 + 2*i; w = chip.mem[a >> 2]; g = a[1] ? w[31:16] : w[15:0];
            if (g !== y(i)) begin
                fails = fails + 1; $display("  global[%0d] = %0d, want %0d", a, g, y(i));
            end
        end
        uart_recv(b);
        $display("host CPU verdict: '%c'; SDRAM %0d violations", b, chip.violations);
        if (b !== "P") fails = fails + 1;
        if (chip.violations != 0) fails = fails + 1;
        if (fails == 0)
            $display("RESULT: PASS - RV32I host loaded the kernel, launched 2 blocks, read results from SDRAM: all right");
        else
            $display("RESULT: FAIL - %0d problem(s)", fails);
        $finish;
    end
    initial begin
        repeat (1000000) @(posedge clk);
        $display("RESULT: FAIL - timeout (cpu halted=%0b pc=%08x)", dut.cpu_halted, dut.host.u_cpu.pc);
        $finish;
    end
endmodule
