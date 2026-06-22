`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// General-purpose load -> run -> read-back, end to end in sim (the real HW flow).
//
// Bit-bangs a [header][program][data] frame into the UART exactly as a host
// would:
//     header : instr_size (16-bit WORDS, LE) | data_size (bytes, LE)
//     program: each 16-bit word as low byte then high byte
//     data   : raw payload bytes (broadcast into BOTH cores' memory)
// The DMA loads the program into instruction RAM and the data into memory, then
// starts the GPU. Both cores run software/sum_kernel.asm over the same data and
// each emits the framed result [len=1][sum]; we decode the UART reply and check.
//
//   data = {10,20,30,40} -> sum = 100 -> reply = 01 64 01 64
//
// Small UART divisor (CLK_FREQ/BAUD_RATE = BIT_CYCLES) keeps the sim fast.
// ============================================================================
module tb;
    localparam PROG_WORDS = 18;          // software/sum_kernel.hex length
    // 4 real bytes {10,20,30,40} + 1 pad: the DMA drops the LAST payload byte
    // (documented loading/mux race), so we pad so the drop hits the pad, not
    // mem[3]. The kernel only sums mem[0..3].
    localparam DATA_BYTES = 5;
    localparam BIT_CYCLES = 16;          // = CLK_FREQ/BAUD_RATE below

    reg  clk = 0;
    reg  uart_line = 1'b1;               // host -> board, UART idle = high
    wire uart_tx;                        // board -> host
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(DATA_BYTES),
        .CLK_FREQ(BIT_CYCLES),
        .BAUD_RATE(1)
    ) dut (
        .clk(clk),
        .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx),
        .led(led)
    );

    always #5 clk = ~clk;

    // ---- program + data to send ----
    reg [15:0] prog [0:PROG_WORDS-1];
    reg [7:0]  data [0:DATA_BYTES-1];
    localparam [7:0] EXPECT_SUM = 8'd100; // 10+20+30+40

    // ---- drive one 8N1 UART frame onto the host->board line, LSB first ----
    task uart_send(input [7:0] b);
        integer k;
        begin
            uart_line = 1'b0;                         // start bit
            repeat (BIT_CYCLES) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_line = b[k];                     // data, LSB first
                repeat (BIT_CYCLES) @(posedge clk);
            end
            uart_line = 1'b1;                         // stop bit
            repeat (BIT_CYCLES) @(posedge clk);
        end
    endtask

    // ---- decode one 8N1 frame coming back from the board ----
    task uart_recv(output [7:0] b);
        integer k;
        begin
            @(negedge uart_tx);                                  // start bit
            repeat (BIT_CYCLES + BIT_CYCLES/2) @(posedge clk);   // center of bit 0
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = uart_tx;
                repeat (BIT_CYCLES) @(posedge clk);
            end
        end
    endtask

    reg [7:0] r0, r1, r2, r3;
    integer i, fails;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/sum_kernel.hex", prog);
        data[0] = 8'd10; data[1] = 8'd20; data[2] = 8'd30; data[3] = 8'd40;
        data[4] = 8'd0;  // pad (absorbs the DMA final-byte drop)

        // let the power-on reset settle
        repeat (64) @(posedge clk);

        // Real BRAM powers up to 0; sim is X. Zero the low memory both cores
        // read so an unwritten cell can't poison the result with X.
        for (i = 0; i < 16; i = i + 1) begin
            dut.pipe.u_mem.mem[i]   = 8'd0;
            dut.pipe.u_mem_1.mem[i] = 8'd0;
        end

        // ---- header: instr_size (words) LE, then data_size (bytes) LE ----
        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(DATA_BYTES % 256); uart_send(DATA_BYTES / 256);

        // ---- program: each word low byte then high byte ----
        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]);
            uart_send(prog[i][15:8]);
        end

        // ---- data payload ----
        for (i = 0; i < DATA_BYTES; i = i + 1)
            uart_send(data[i]);

        // ---- reply: [len][sum] from core 0, then [len][sum] from core 1 ----
        uart_recv(r0); uart_recv(r1); uart_recv(r2); uart_recv(r3);

        fails = 0;
        if (r0 !== 8'd1)       begin fails=fails+1; $display("  core0 len = %0d (expected 1)",   r0); end
        if (r1 !== EXPECT_SUM) begin fails=fails+1; $display("  core0 sum = %0d (expected %0d)",  r1, EXPECT_SUM); end
        if (r2 !== 8'd1)       begin fails=fails+1; $display("  core1 len = %0d (expected 1)",   r2); end
        if (r3 !== EXPECT_SUM) begin fails=fails+1; $display("  core1 sum = %0d (expected %0d)",  r3, EXPECT_SUM); end

        $display("reply bytes: %02x %02x %02x %02x", r0, r1, r2, r3);
        if (fails == 0)
            $display("RESULT: PASS - loaded kernel ran on both cores, sum=%0d read back", EXPECT_SUM);
        else
            $display("RESULT: FAIL - %0d mismatch(es)", fails);
        $finish;
    end

    // safety timeout
    initial begin
        repeat (2000000) @(posedge clk);
        $display("RESULT: FAIL - timeout (no/short reply, got %02x %02x %02x %02x)", r0, r1, r2, r3);
        $finish;
    end
endmodule
