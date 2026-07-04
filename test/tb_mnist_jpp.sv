`timescale 1ns/1ns
// MNIST FC classifier through the CURRENT maintained UART->DMA->run->readback
// protocol (same as tb_loadrun), instead of the stale tb_mnist harness.
// Streams the J++-COMPILED classifier (mnist_fc.jpp -> mnist_fc_jpp.hex).
module tb;
    localparam PROG_WORDS = 41;          // software/mnist_fc_jpp.hex length
    localparam REAL_BYTES = 3380;        // fc_payload0.hex
    localparam DATA_BYTES = REAL_BYTES + 1; // +1 pad absorbs DMA final-byte drop
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(DATA_BYTES),
        .CLK_FREQ(BIT_CYCLES),
        .BAUD_RATE(1),
        .WARPS_PER_CORE(1),   // FC-MAC accumulator is thread-0 driven; 2 warps
        .BLOCK_DIM(4)         // double-drive every FMAC and corrupt the scores
    ) dut (
        .clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led)
    );

    always #5 clk = ~clk;

    reg [15:0] prog [0:PROG_WORDS-1];
    reg [7:0]  data [0:DATA_BYTES-1];

    task uart_send(input [7:0] b);
        integer k;
        begin
            uart_line = 1'b0; repeat (BIT_CYCLES) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_line = b[k]; repeat (BIT_CYCLES) @(posedge clk);
            end
            uart_line = 1'b1; repeat (BIT_CYCLES) @(posedge clk);
        end
    endtask

    task uart_recv(output [7:0] b);
        integer k;
        begin
            @(negedge uart_tx);
            repeat (BIT_CYCLES + BIT_CYCLES/2) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = uart_tx; repeat (BIT_CYCLES) @(posedge clk);
            end
        end
    endtask

    reg [7:0] r0, r1, r2, r3;
    integer i;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/mnist_fc_jpp.hex", prog);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/mnist_data/fc_payload0.hex", data);
        data[REAL_BYTES] = 8'd0; // pad

        repeat (64) @(posedge clk);

        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(DATA_BYTES % 256); uart_send(DATA_BYTES / 256);
        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]); uart_send(prog[i][15:8]);
        end
        for (i = 0; i < DATA_BYTES; i = i + 1) uart_send(data[i]);

        // Each core emits ONE byte: its predicted digit. r0 = core 0, r1 = core 1.
        uart_recv(r0); uart_recv(r1);
        $display("predicted digits: core0=%0d core1=%0d", r0, r1);
        if (r0 === 8'd7) $display("RESULT: PASS - on-chip FC classifier predicts 7");
        else             $display("RESULT: FAIL - core0 digit=%0d (expected 7)", r0);
        $finish;
    end

    initial begin
        repeat (6000000) @(posedge clk);
        $display("RESULT: FAIL - timeout, got %02x %02x %02x %02x", r0, r1, r2, r3);
        $finish;
    end
endmodule
