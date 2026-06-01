`default_nettype none
`timescale 1ns/1ns

// Phase 1 (wider addressing) test: stream 320 bytes, run addr_kernel.hex which
// walks base to 300 via ADDB and LDRs mem[300] into R3. Address 300 is > 255,
// so this is unreachable without the base pointer.
//
// Build with -DKERNEL_HEX="...addr_kernel.hex".
module tb;
    localparam PAYLOAD    = 320;
    localparam BIT_CYCLES = 16;        // fast sim baud (matches top CLK_FREQ/BAUD below)

    reg clk = 0;
    reg uart_line = 1'b1;
    wire uart_tx_out;
    wire [5:0] led;

    top #(.PAYLOAD_BYTES(PAYLOAD), .CLK_FREQ(16), .BAUD_RATE(1)) dut (
        .clk(clk), .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx_out), .led(led)
    );

    always #5 clk = ~clk;

    reg [7:0] sent [0:PAYLOAD-1];

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
        repeat (40) @(posedge clk);
        for (i = 0; i < PAYLOAD; i = i + 1) begin
            sent[i] = (i * 53 + 17) & 8'hFF;
            uart_send(sent[i]);
        end
        t = 0;
        while (t < 20000 && dut.done !== 1'b1) begin @(posedge clk); t = t + 1; end

        r3 = dut.uut.compute_core_0.thread_block[0].thread_regs.registers[3];
        $display("done=%0b   R3 = %02x   mem[300] expected = %02x", dut.done, r3, sent[300]);
        if (dut.done === 1'b1 && r3 === sent[300])
            $display("RESULT: PASS - base+offset LDR reached address 300");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
