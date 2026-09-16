`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Two-layer quantized MLP, compiled end to end.
//
//   software/export_model.py        model -> graph JSON
//   src/bin/graph_compiler.rs       JSON  -> data image + kernel + expected bytes
//   src/main.rs                     asm   -> hex
//   this testbench                  streams both over UART and checks the reply
//
// 169 -> 32 (relu) -> 10, int8 weights, requantized between layers with FOUT.
// NOTHING about the model is in the bitstream: every weight arrives as data.
//
// The kernel emits [len][10 scores][argmax]. We check ALL of it against the
// compiler's own reference evaluator, not just the prediction -- a single wrong
// weight moves a score, but argmax would hide it.
// ============================================================================
module tb;
    localparam PROG_WORDS = 82;          // build/mlp_169_32_10.hex
    localparam REAL_BYTES = 5897;        // build/mlp_169_32_10.data.hex
    localparam DATA_BYTES = REAL_BYTES + 1;  // +1: the DMA drops the final byte
    localparam N_REPLY    = 12;          // [len][10 scores][pred]
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(1),
        .CLK_FREQ(BIT_CYCLES),
        .BAUD_RATE(1),
        .WARPS_PER_CORE(1),   // FC-MAC accumulator is thread-0 driven
        .BLOCK_DIM(4)
    ) dut (
        .clk(clk),
        .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx),
        .led(led)
    );

    always #5 clk = ~clk;

    reg [15:0] prog [0:PROG_WORDS-1];
    reg [7:0]  data [0:DATA_BYTES-1];
    reg [7:0]  want   [0:N_REPLY-1];  // 'expect' is a reserved SVA keyword
    reg [7:0]  got    [0:N_REPLY-1];

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

    integer i, fails;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/mlp_169_32_10.hex", prog);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/mlp_169_32_10.data.hex", data);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/mlp_169_32_10.expect.hex", want);
        data[REAL_BYTES] = 8'd0;   // pad absorbs the DMA's dropped final byte

        repeat (64) @(posedge clk);

        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(DATA_BYTES % 256); uart_send(DATA_BYTES / 256);
        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]); uart_send(prog[i][15:8]);
        end
        for (i = 0; i < DATA_BYTES; i = i + 1) uart_send(data[i]);

        for (i = 0; i < N_REPLY; i = i + 1) uart_recv(got[i]);

        fails = 0;
        $display("        idx   got  expect");
        for (i = 0; i < N_REPLY; i = i + 1) begin
            if (got[i] !== want[i]) begin
                fails = fails + 1;
                $display("  FAIL  %0d %6d %7d", i, got[i], want[i]);
            end else begin
                $display("        %0d %6d %7d", i, got[i], want[i]);
            end
        end

        if (fails == 0)
            $display("RESULT: PASS - 2-layer int8 MLP matches the reference exactly (pred=%0d)",
                     got[N_REPLY-1]);
        else
            $display("RESULT: FAIL - %0d of %0d bytes wrong", fails, N_REPLY);
        $finish;
    end

    initial begin
        repeat (40000000) @(posedge clk);
        $display("RESULT: FAIL - global timeout");
        $finish;
    end
endmodule
