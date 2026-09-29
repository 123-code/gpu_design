`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// The whole MNIST CNN written in J++ (software/mnist.jpp), on the board's
// configuration: 2 cores x 1 warp x 9 threads.
//
//   conv 3x3 -> maxpool 2x2 -> dense 169->10 -> argmax, all computed by the GPU.
//
// Checks, against the bit-exact reference (mnist_ref.py via run_mnist_jpp.py --sim):
//   * all 676 conv-map bytes and all 169 pooled bytes in core 0's memory
//   * the predicted digit emitted over UART by BOTH cores
// Also reports the GPU run length in clock cycles (DMA start -> core 0 done).
// ============================================================================
module tb;
    localparam PROG_WORDS = 186;         // software/mnist_jpp.hex
    localparam DATA_BYTES = 3352;        // image + maps + spare + dense weights + pad
    localparam CONV_BASE  = 784;
    localparam POOL_BASE  = 1460;
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(1), .CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1),
        .WARPS_PER_CORE(1), .THREADS_PER_BLOCK(9), .BLOCK_DIM(9)
    ) dut (.clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led));

    always #5 clk = ~clk;

    reg [15:0] prog [0:PROG_WORDS-1];
    reg [7:0]  data [0:DATA_BYTES-1];
    reg [7:0]  conv [0:675];
    reg [7:0]  pool [0:168];
    reg [7:0]  want [0:0];
    reg [7:0]  got0, got1;

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

    integer i, conv_bad, pool_bad;
    time t_start = 0, t_done = 0;
    always @(posedge dut.pipe.gpu_start) t_start = $time;
    always @(posedge dut.uut.core_0_done) t_done = $time;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/mnist_jpp.hex", prog);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/mnist_jpp.data.hex", data);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/mnist_jpp.conv.hex", conv);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/mnist_jpp.pool.hex", pool);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/mnist_jpp.expect.hex", want);

        repeat (64) @(posedge clk);
        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(DATA_BYTES % 256); uart_send(DATA_BYTES / 256);
        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]); uart_send(prog[i][15:8]);
        end
        for (i = 0; i < DATA_BYTES; i = i + 1) uart_send(data[i]);

        uart_recv(got0);
        uart_recv(got1);
        repeat (32) @(posedge clk);

        conv_bad = 0; pool_bad = 0;
        for (i = 0; i < 676; i = i + 1)
            if (dut.pipe.u_mem.mem[CONV_BASE + i] !== conv[i]) begin
                if (conv_bad < 5) $display("  conv[%0d] = %0d, expected %0d", i, dut.pipe.u_mem.mem[CONV_BASE + i], conv[i]);
                conv_bad = conv_bad + 1;
            end
        for (i = 0; i < 169; i = i + 1)
            if (dut.pipe.u_mem.mem[POOL_BASE + i] !== pool[i]) begin
                if (pool_bad < 5) $display("  pool[%0d] = %0d, expected %0d", i, dut.pipe.u_mem.mem[POOL_BASE + i], pool[i]);
                pool_bad = pool_bad + 1;
            end

        $display("  conv map: %0d/676 wrong   pooled map: %0d/169 wrong", conv_bad, pool_bad);
        $display("  GPU run: %0d clock cycles", (t_done - t_start) / 10);
        $display("  prediction: core0=%0d core1=%0d expected=%0d", got0, got1, want[0]);
        if (conv_bad == 0 && pool_bad == 0 && got0 === want[0] && got1 === want[0])
            $display("RESULT: PASS - J++ MNIST matches the reference (maps and prediction %0d)", want[0]);
        else
            $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        repeat (60000000) @(posedge clk);
        $display("RESULT: FAIL - global timeout");
        $finish;
    end
endmodule
