`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// LDI / LUI proof, end to end in sim (same load->run->readback flow as
// tb_loadrun). Loads ldi_kernel over UART; each core builds the 16-bit constant
// 0x0164 with LDI and emits its low then high byte. A correct build replies
// [100][1] per core -> 64 01 64 01.
// ============================================================================
module tb;
    localparam PROG_WORDS = 9;           // software/ldi_kernel.hex length
    localparam DATA_BYTES = 2;           // kernel reads no data; DMA still needs a payload
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
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

    reg [15:0] prog [0:PROG_WORDS-1];
    reg [7:0]  data [0:DATA_BYTES-1];
    localparam [7:0] EXPECT_LO = 8'd100; // 0x64
    localparam [7:0] EXPECT_HI = 8'd1;   // 0x01

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

    reg [7:0] r0, r1, r2, r3;
    integer i, fails;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/ldi_kernel.hex", prog);
        data[0] = 8'd0; data[1] = 8'd0;

        repeat (64) @(posedge clk);
        for (i = 0; i < 16; i = i + 1) begin
            dut.pipe.u_mem.mem[i]   = 8'd0;
            dut.pipe.u_mem_1.mem[i] = 8'd0;
        end

        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(DATA_BYTES % 256); uart_send(DATA_BYTES / 256);
        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]);
            uart_send(prog[i][15:8]);
        end
        for (i = 0; i < DATA_BYTES; i = i + 1)
            uart_send(data[i]);

        // core0 emits [lo][hi], then core1 emits [lo][hi]
        uart_recv(r0); uart_recv(r1); uart_recv(r2); uart_recv(r3);

        fails = 0;
        if (r0 !== EXPECT_LO) begin fails=fails+1; $display("  core0 low  = %0d (expected %0d)", r0, EXPECT_LO); end
        if (r1 !== EXPECT_HI) begin fails=fails+1; $display("  core0 high = %0d (expected %0d)", r1, EXPECT_HI); end
        if (r2 !== EXPECT_LO) begin fails=fails+1; $display("  core1 low  = %0d (expected %0d)", r2, EXPECT_LO); end
        if (r3 !== EXPECT_HI) begin fails=fails+1; $display("  core1 high = %0d (expected %0d)", r3, EXPECT_HI); end

        $display("reply bytes: %02x %02x %02x %02x  (expect 64 01 64 01)", r0, r1, r2, r3);
        if (fails == 0)
            $display("RESULT: PASS - LDI built 0x0164; low=100 high=1 read back on both cores");
        else
            $display("RESULT: FAIL - %0d mismatch(es)", fails);
        $finish;
    end

    initial begin
        repeat (2000000) @(posedge clk);
        $display("RESULT: FAIL - timeout (got %02x %02x %02x %02x)", r0, r1, r2, r3);
        $finish;
    end
endmodule
