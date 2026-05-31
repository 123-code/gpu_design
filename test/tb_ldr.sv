`default_nettype none
`timescale 1ns/1ns

// Isolated LDR / Host-to-Device test.
// Streams a short payload into the accelerator over UART; the DMA wakes the GPU,
// which runs ldr_kernel.hex (LDR mem[0..2] -> R5,R6,R7). We then check those
// registers hold the streamed bytes.
//
// Build with -DKERNEL_HEX="...ldr_kernel.hex".
module tb;
    localparam PAYLOAD    = 8;
    localparam BIT_CYCLES = 234;        // matches uart_rx BIT_TICK (27MHz/115200)

    reg clk = 0;
    reg uart_line = 1'b1;
    wire uart_tx_out;
    wire [5:0] led;

    top #(.PAYLOAD_BYTES(PAYLOAD)) dut (
        .clk(clk),
        .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx_out),
        .led(led)
    );

    always #5 clk = ~clk;

    reg [7:0] sent [0:PAYLOAD-1];

    // Send one 8N1 frame, LSB first.
    task uart_send(input [7:0] b);
        integer k;
        begin
            uart_line = 1'b0; repeat (BIT_CYCLES) @(posedge clk);          // start
            for (k = 0; k < 8; k = k + 1) begin
                uart_line = b[k]; repeat (BIT_CYCLES) @(posedge clk);      // data
            end
            uart_line = 1'b1; repeat (BIT_CYCLES) @(posedge clk);          // stop
        end
    endtask

    integer i, t;
    reg [7:0] r5, r6, r7;
    initial begin
        repeat (40) @(posedge clk);    // let the power-on reset clear

        // Stream the payload.
        for (i = 0; i < PAYLOAD; i = i + 1) begin
            sent[i] = (i * 53 + 17) & 8'hFF;
            uart_send(sent[i]);
        end

        // Wait for the DMA to wake the GPU and the kernel to finish.
        t = 0;
        while (t < 20000 && dut.done !== 1'b1) begin @(posedge clk); t = t + 1; end

        r5 = dut.uut.compute_core_0.thread_block[0].thread_regs.registers[5];
        r6 = dut.uut.compute_core_0.thread_block[0].thread_regs.registers[6];
        r7 = dut.uut.compute_core_0.thread_block[0].thread_regs.registers[7];

        $display("done=%0b after %0d cycles", dut.done, t);
        $display("R5 = %02x (mem[0] expected %02x)", r5, sent[0]);
        $display("R6 = %02x (mem[1] expected %02x)", r6, sent[1]);
        $display("R7 = %02x (mem[2] expected %02x)", r7, sent[2]);

        if (dut.done === 1'b1 && r5 === sent[0] && r6 === sent[1] && r7 === sent[2])
            $display("RESULT: PASS - LDR pulled streamed bytes from SRAM into registers");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
