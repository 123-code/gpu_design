`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// 32-bit MAC read-out validation.
//
// Streams software/mac_read32.asm over UART and runs it. The kernel accumulates
// a 32-bit MAC result (8 * 30 * 20 = 4800 = 0x12C0), reads all four bytes with
// the new `MAC Rd,#n` (n = 0..3), and emits a little-endian [len=4][b0..b3]
// frame. We decode core 0's frame and reassemble the full 32-bit value.
//
// The OLD low-byte-only path could only ever surface 0xC0 (192). Recovering the
// whole 4800 is the proof that the 32-bit result is no longer truncated.
// ============================================================================
module tb;
    localparam PROG_WORDS = 22;          // software/mac_read32.hex length
    localparam BIT_CYCLES = 16;          // = CLK_FREQ/BAUD_RATE below

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(1),
        .CLK_FREQ(BIT_CYCLES),
        .BAUD_RATE(1)
    ) dut (
        .clk(clk),
        .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx),
        .led(led)
    );

    always #5 clk = ~clk;

    reg [15:0] prog [0:PROG_WORDS-1];

    task uart_send(input [7:0] b);
        integer k;
        begin
            uart_line = 1'b0;
            repeat (BIT_CYCLES) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_line = b[k];
                repeat (BIT_CYCLES) @(posedge clk);
            end
            uart_line = 1'b1;
            repeat (BIT_CYCLES) @(posedge clk);
        end
    endtask

    task uart_recv(output [7:0] b);
        integer k;
        begin
            @(negedge uart_tx);
            repeat (BIT_CYCLES + BIT_CYCLES/2) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = uart_tx;
                repeat (BIT_CYCLES) @(posedge clk);
            end
        end
    endtask

    reg [7:0]  len, b0, b1, b2, b3;
    reg [31:0] got, expect_val;
    integer i, fails;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/mac_read32.hex", prog);

        repeat (64) @(posedge clk);

        // header: instr_size (words) LE, data_size = 0
        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(8'd0);             uart_send(8'd0);
        // program: low byte then high byte per word
        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]);
            uart_send(prog[i][15:8]);
        end

        // core 0's frame: [len][b0][b1][b2][b3]
        uart_recv(len);
        uart_recv(b0); uart_recv(b1); uart_recv(b2); uart_recv(b3);

        got = {b3, b2, b1, b0};                 // reassemble little-endian
        // The hardware MAC result is the ground truth (independent of my arithmetic).
        expect_val = dut.uut.compute_core_0.u_mac.result_out;

        $display("frame: len=%0d  bytes = %02x %02x %02x %02x", len, b0, b1, b2, b3);
        $display("reassembled 32-bit = %0d (0x%08x)", got, got);
        $display("MAC unit result_out = %0d (0x%08x)", expect_val, expect_val);

        fails = 0;
        if (len !== 8'd4)         begin fails=fails+1; $display("  FAIL: len = %0d (expected 4)", len); end
        if (got !== expect_val)   begin fails=fails+1; $display("  FAIL: reassembled != MAC unit result"); end
        if (got <= 32'd255)       begin fails=fails+1; $display("  FAIL: value <= 255 (test would not exercise high bytes)"); end
        if (got !== 32'd4800)     begin fails=fails+1; $display("  FAIL: value = %0d (expected 4800)", got); end

        if (fails == 0)
            $display("RESULT: PASS - full 32-bit MAC result %0d read back as 4 bytes", got);
        else
            $display("RESULT: FAIL - %0d mismatch(es)", fails);
        $finish;
    end

    initial begin
        repeat (2000000) @(posedge clk);
        $display("RESULT: FAIL - global timeout");
        $finish;
    end
endmodule
