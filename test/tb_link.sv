`default_nettype none
`timescale 1ns/1ns

// Two boards, one link: an all-reduce over the board-to-board link.
//
// Each board is a full `top` with its own SDRAM, joined by two wires
// (A.link_tx -> B.link_rx and back). The host loads a different 8-element
// vector into each board's global memory.
//   phase 1 (link_phase1.asm): each board stores its vector into the OTHER
//            board's global memory (address bit 15 = remote)
//   phase 2 (link_phase2.asm): each board adds its own vector and the one
//            that arrived, and stores the sum
// Both boards must end with v_A + v_B, and each link must have carried
// exactly 8 packets.

// One board plus the host side of its UART
module board #(parameter BIT_CYCLES = 16) (
    input  wire clk,
    output wire link_tx,
    input  wire link_rx
);
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;
    wire sd_clk, sd_cke, sd_cs_n, sd_cas_n, sd_ras_n, sd_we_n;
    wire [3:0] sd_dqm; wire [10:0] sd_addr; wire [1:0] sd_ba; wire [31:0] sd_dq;

    top #(.CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1), .BLOCK_DIM(4), .SDRAM_INIT_CYCLES(200)) dut (
        .clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led),
        .link_tx(link_tx), .link_rx(link_rx),
        .O_sdram_clk(sd_clk), .O_sdram_cke(sd_cke), .O_sdram_cs_n(sd_cs_n),
        .O_sdram_cas_n(sd_cas_n), .O_sdram_ras_n(sd_ras_n), .O_sdram_wen_n(sd_we_n),
        .O_sdram_dqm(sd_dqm), .O_sdram_addr(sd_addr), .O_sdram_ba(sd_ba), .IO_sdram_dq(sd_dq)
    );
    sdram_model chip (
        .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .ba(sd_ba), .addr(sd_addr), .dqm(sd_dqm), .dq(sd_dq)
    );

    `include "test/host_uart.svh"

    function automatic [15:0] g16(input integer a);
        reg [31:0] w;
        begin w = chip.mem[a >> 2]; g16 = a[1] ? w[31:16] : w[15:0]; end
    endfunction
endmodule

module tb;
    reg clk = 0;
    always #5 clk = ~clk;
    wire a_to_b, b_to_a;
    board A (.clk(clk), .link_tx(a_to_b), .link_rx(b_to_a));
    board B (.clk(clk), .link_tx(b_to_a), .link_rx(a_to_b));

    function automatic [15:0] va(input integer i); va = 100 + 3*i;  endfunction
    function automatic [15:0] vb(input integer i); vb = 1000 + 7*i; endfunction

    integer i, fails;
    reg [15:0] p1 [0:255];
    reg [15:0] p2 [0:255];
    integer n1, n2;
    initial begin
        for (i = 0; i < 256; i = i + 1) begin p1[i] = 16'hxxxx; p2[i] = 16'hxxxx; end
        $readmemh("software/link_phase1.hex", p1);
        $readmemh("software/link_phase2.hex", p2);
        n1 = 0; while (^p1[n1] !== 1'bx) n1 = n1 + 1;
        n2 = 0; while (^p2[n2] !== 1'bx) n2 = n2 + 1;
        repeat (300) @(posedge clk);

        // phase 1: each board gets its vector (to global memory) + kernel 1
        for (i = 0; i < 256; i = i + 1) begin A.host_prog[i] = p1[i]; B.host_prog[i] = p1[i]; end
        for (i = 0; i < 8; i = i + 1) begin
            A.host_data[2*i] = va(i) & 8'hff; A.host_data[2*i+1] = va(i) >> 8;
            B.host_data[2*i] = vb(i) & 8'hff; B.host_data[2*i+1] = vb(i) >> 8;
        end
        fork
            A.send_frame_ex(n1, 16, 2, 1);
            B.send_frame_ex(n1, 16, 2, 1);
        join
        wait (A.dut.done && B.dut.done);
        // `done` covers our own link FIFO; give the peer's receiver time to
        // turn the last packet into an SDRAM write
        repeat (200) @(posedge clk);
        $display("phase 1: link A->B %0d packets, B->A %0d packets",
                 B.dut.lk_link_received, A.dut.lk_link_received);

        // phase 2: kernel 2, no payload
        for (i = 0; i < 256; i = i + 1) begin A.host_prog[i] = p2[i]; B.host_prog[i] = p2[i]; end
        fork
            A.send_frame_ex(n2, 0, 2, 0);
            B.send_frame_ex(n2, 0, 2, 0);
        join
        @(posedge clk);
        wait (A.dut.done && B.dut.done);
        repeat (50) @(posedge clk);

        fails = 0;
        for (i = 0; i < 8; i = i + 1) begin
            if (A.g16(512 + 2*i) !== va(i) + vb(i) || B.g16(512 + 2*i) !== va(i) + vb(i)) begin
                fails = fails + 1;
                $display("  element %0d: A %0d, B %0d, want %0d", i, A.g16(512 + 2*i), B.g16(512 + 2*i), va(i) + vb(i));
            end
        end
        if (B.dut.lk_link_received != 8 || A.dut.lk_link_received != 8) fails = fails + 1;
        if (A.chip.violations != 0 || B.chip.violations != 0) fails = fails + 1;
        if (fails == 0)
            $display("RESULT: PASS - all-reduce over the board link: both boards hold v_A + v_B (8 packets each way)");
        else
            $display("RESULT: FAIL - %0d problem(s)", fails);
        $finish;
    end
    initial begin
        repeat (3000000) @(posedge clk);
        $display("RESULT: FAIL - timeout");
        $finish;
    end
endmodule
