`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// FACC validation: read the raw 32-bit FC accumulator back out, signed.
//
// Streams software/facc_test.asm and decodes the [len=8][4 bytes][4 bytes]
// frame core 0 emits:
//   phase 1  8 * 30 * (+20) =  4800  (0x000012C0)  - positive path
//   phase 2  8 * 30 * (-1)  =  -240  (0xFFFFFF10)  - sign survives the readback
// then FOUT (requantize + saturate + ReLU in one op):
//   phase 3  4800   >>> 8 =   18   - normal requantize
//   phase 4  -240   >>> 8 =    0   - negative clamps to 0 (this IS the ReLU)
//   phase 5  259080 >>> 8 =  255   - saturates instead of wrapping
//
// Phase 2 is the real test. Before this change the only way to read fc_mac was
// FBEST (best_idx), so a hidden layer could not see its own pre-activation at
// all — and a pre-activation is negative about half the time, which is exactly
// what ReLU has to act on.
// ============================================================================
module tb;
    localparam PROG_WORDS = 87;          // software/facc_test.hex length
    localparam BIT_CYCLES = 16;          // = CLK_FREQ/BAUD_RATE below

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(1),
        .CLK_FREQ(BIT_CYCLES),
        .BAUD_RATE(1),
        .WARPS_PER_CORE(1),   // FC-MAC accumulator is thread-0 driven; 2 warps
        .BLOCK_DIM(4)         // would double-drive every FMAC
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

    reg [7:0]  len;
    reg [7:0]  p1 [0:3];
    reg [7:0]  p2 [0:3];
    reg [7:0]  p3, p4, p5;
    reg signed [31:0] got1, got2;
    integer i, fails;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/facc_test.hex", prog);

        repeat (64) @(posedge clk);

        // header: instr_size (words) LE, data_size = 0
        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(8'd0);             uart_send(8'd0);
        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]);
            uart_send(prog[i][15:8]);
        end

        uart_recv(len);
        for (i = 0; i < 4; i = i + 1) uart_recv(p1[i]);
        for (i = 0; i < 4; i = i + 1) uart_recv(p2[i]);
        uart_recv(p3); uart_recv(p4); uart_recv(p5);

        got1 = {p1[3], p1[2], p1[1], p1[0]};
        got2 = {p2[3], p2[2], p2[1], p2[0]};

        $display("frame: len=%0d", len);
        $display("phase1 bytes = %02x %02x %02x %02x -> %0d (0x%08x)",
                 p1[0], p1[1], p1[2], p1[3], got1, got1);
        $display("phase2 bytes = %02x %02x %02x %02x -> %0d (0x%08x)",
                 p2[0], p2[1], p2[2], p2[3], got2, got2);

        $display("FOUT: p3=%0d (want 18)  p4=%0d (want 0, ReLU)  p5=%0d (want 255, sat)",
                 p3, p4, p5);

        fails = 0;
        if (len  !== 8'd11)         begin fails=fails+1; $display("  FAIL: len = %0d (expected 11)", len); end
        if (p3   !== 8'd18)         begin fails=fails+1; $display("  FAIL: FOUT requantize = %0d (expected 18)", p3); end
        if (p4   !== 8'd0)          begin fails=fails+1; $display("  FAIL: FOUT ReLU = %0d (expected 0)", p4); end
        if (p5   !== 8'd255)        begin fails=fails+1; $display("  FAIL: FOUT saturate = %0d (expected 255)", p5); end
        if (got1 !== 32'sd4800)     begin fails=fails+1; $display("  FAIL: phase1 = %0d (expected 4800)", got1); end
        if (got2 !== -32'sd240)     begin fails=fails+1; $display("  FAIL: phase2 = %0d (expected -240)", got2); end

        if (fails == 0)
            $display("RESULT: PASS - FACC reads signed acc (%0d, %0d); FOUT requantizes/ReLUs/saturates (%0d, %0d, %0d)",
                     got1, got2, p3, p4, p5);
        else
            $display("RESULT: FAIL - %0d mismatch(es)", fails);
        $finish;
    end

    initial begin
        repeat (4000000) @(posedge clk);
        $display("RESULT: FAIL - global timeout");
        $finish;
    end
endmodule
