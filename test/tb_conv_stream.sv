`default_nettype none
`timescale 1ns/1ns

// End-to-end streaming convolution:
//   stream 9 pixels + 9 weights over UART -> DMA -> SRAM -> GPU runs
//   conv_stream_kernel.hex (LDR each operand, MACL, MAC R3).
//
//   pixels  = 64 (x9)
//   weights = 8 (x8), then -8 (=0xF8 signed)  <-- signed 8-bit, from memory
//   sum = 8*(64*8) + 64*(-8) = 4096 - 512 = 3584 ; 3584 >> 8 = 14  => R3 = 14
//
// Build with -DKERNEL_HEX="...conv_stream_kernel.hex".
module tb;
    localparam PAYLOAD    = 18;
    localparam BIT_CYCLES = 234;

    reg clk = 0;
    reg uart_line = 1'b1;
    wire uart_tx_out;
    wire [5:0] led;

    top #(.PAYLOAD_BYTES(PAYLOAD)) dut (
        .clk(clk), .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx_out), .led(led)
    );

    always #5 clk = ~clk;

    reg [7:0] payload [0:PAYLOAD-1];

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

    integer i, t;
    reg [7:0] r3;
    initial begin
        // Build the payload: 9 pixels, then 9 weights (last weight signed -8).
        for (i = 0; i < 9;  i = i + 1) payload[i]   = 8'd64;   // pixels
        for (i = 0; i < 8;  i = i + 1) payload[9+i] = 8'd8;    // weights +8
        payload[17] = 8'hF8;                                   // weight -8 (signed)

        repeat (40) @(posedge clk);

        for (i = 0; i < PAYLOAD; i = i + 1) uart_send(payload[i]);

        // Wait for the GPU to finish the conv.
        t = 0;
        while (t < 40000 && dut.done !== 1'b1) begin @(posedge clk); t = t + 1; end

        r3 = dut.uut.compute_core_0.thread_block[0].thread_regs.registers[3];
        $write("mac_buf =");
        for (i = 0; i < 18; i = i + 1) $write(" %0d", dut.uut.compute_core_0.mac_buf[i]);
        $display("");
        $display("done=%0b   R3 (conv result) = %0d (expected 14)", dut.done, r3);
        if (dut.done === 1'b1 && r3 === 8'd14)
            $display("RESULT: PASS - streamed image+signed-weights ran through the MAC");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
