`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// FULL on-chip MNIST CNN via the REAL load->run->readback flow (DMA/UART), on
// the CURRENT dual-core / 16-bit datapath. Single-thread config (the kernel is
// sequential: thread 0 does the whole Conv->Pool->Scatter->FC->argmax).
//
// Streams [header][mnist_full.hex][image0 bytes]; each core emits its predicted
// digit (1 raw byte). Expect 7 for image 0.
// ============================================================================
module tb;
    localparam PROG_WORDS = 170;         // software/mnist_full.hex (GPGPU conv)
    localparam IMG_BYTES  = 784;
    localparam DATA_BYTES = IMG_BYTES + 1; // +1 pad (DMA drops the last byte)
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    // Single-thread launch: 1 warp x 1 lane, BLOCK_DIM 1.
    top #(
        .PAYLOAD_BYTES(DATA_BYTES),
        .CLK_FREQ(BIT_CYCLES),
        .BAUD_RATE(1),
        .BLOCK_DIM(1),
        .THREADS_PER_BLOCK(1),
        .WARPS_PER_CORE(1)
    ) dut (
        .clk(clk),
        .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx),
        .led(led)
    );

    always #5 clk = ~clk;

    reg [15:0] prog [0:PROG_WORDS-1];
    reg [7:0]  img  [0:IMG_BYTES-1];

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

    reg [7:0] d0, d1;
    integer i;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/mnist_full.hex", prog);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/mnist_data/image0.hex", img);

        repeat (64) @(posedge clk);

        // header: instr_size (words) LE, data_size (bytes) LE
        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(DATA_BYTES % 256); uart_send(DATA_BYTES / 256);
        // program: low byte then high byte
        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]);
            uart_send(prog[i][15:8]);
        end
        // data: the 784-byte image, then 1 pad byte
        for (i = 0; i < IMG_BYTES; i = i + 1) uart_send(img[i]);
        uart_send(8'd0);

        // each core emits its predicted digit
        uart_recv(d0); uart_recv(d1);

        $display("predicted digits: core0=%0d core1=%0d (expected 7)", d0, d1);
        if (d0 === 8'd7 && d1 === 8'd7)
            $display("RESULT: PASS - full on-chip CNN (Conv->Pool->FC) predicts 7");
        else
            $display("RESULT: FAIL - got core0=%0d core1=%0d", d0, d1);
        $finish;
    end

    // safety timeout (the full pipeline is long)
    initial begin
        repeat (60000000) @(posedge clk);
        $display("RESULT: FAIL - timeout (no digit; got %0d %0d)", d0, d1);
        $finish;
    end
endmodule
