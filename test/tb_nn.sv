`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// nn.jpp end-to-end check: a single neuron written in J++.
//
// Streams software/nn.hex over UART, plus the pixel payload, runs it, and reads
// core 0's emitted byte. nn.jpp computes
//   out = sum(pixel[i] * weight[i])  with weights 1,2,3,4,3,2,1,0
// on the vector_mac accelerator. With pixels 1..8 -> out = 64 (0x40).
//
// Two config requirements the MAC path imposes (both learned the hard way):
//   * WARPS_PER_CORE=1 — the 8-slot MAC buffer is thread-0-driven; at 2 warps
//     BOTH warps push, filling the buffer with duplicated early pairs (-> 59).
//   * pad the payload by one byte — the DMA drops the final payload byte, so
//     without the pad mem[7] is never written (x) and poisons the sum.
// ============================================================================
module tb;
    localparam PROG_WORDS = 38;          // software/nn.hex length
    localparam N_PIX      = 9;           // 8 pixels + 1 pad (DMA drops the last byte)
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(N_PIX),
        .CLK_FREQ(BIT_CYCLES),
        .BAUD_RATE(1),
        .WARPS_PER_CORE(1),   // MAC buffer is thread-0 driven; 1 warp only
        .BLOCK_DIM(4)
    ) dut (
        .clk(clk),
        .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx),
        .led(led)
    );

    always #5 clk = ~clk;

    reg [15:0] prog [0:PROG_WORDS-1];
    reg [7:0]  pix  [0:N_PIX-1];

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

    reg [7:0] out;
    integer i;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/nn.hex", prog);
        for (i = 0; i < N_PIX; i = i + 1) pix[i] = (i < 8) ? (i + 1) : 0; // pixels 1..8, then pad

        repeat (64) @(posedge clk);

        // header: instr_size (words) LE, data_size (bytes) LE
        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(N_PIX % 256);      uart_send(N_PIX / 256);
        // program: low byte then high byte per word
        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]);
            uart_send(prog[i][15:8]);
        end
        // data: the 8 pixels
        for (i = 0; i < N_PIX; i = i + 1) uart_send(pix[i]);

        uart_recv(out);   // core 0's neuron output

        $display("neuron output = %0d (0x%02x)", out, out);
        if (out === 8'd64)
            $display("RESULT: PASS - nn.jpp neuron computed 64 on the MAC");
        else
            $display("RESULT: FAIL - got %0d, expected 64", out);
        $finish;
    end

    initial begin
        repeat (2000000) @(posedge clk);
        $display("RESULT: FAIL - global timeout");
        $finish;
    end
endmodule
