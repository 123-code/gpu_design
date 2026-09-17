`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Generic harness for ANY graph_compiler output: compile once, run per model.
//
//   vvp sim_mlc +PROG=k.hex +DATA=d.hex +EXPECT=e.hex
//               +PROG_WORDS=N +DATA_BYTES=N +N_REPLY=N [+MAX_CYCLES=N]
//
// Streams kernel + data image over UART exactly like send_kernel.py, then
// checks every reply byte against the compiler's bit-exact reference. Used by
// software/fuzz_mlc.py (differential fuzzing: random model -> compiler -> RTL).
// Default config matches the board bitstream (oss_build tiny_gpu_ml.fs).
// ============================================================================
module tb;
    parameter WARPS     = 1;
    parameter TPB       = 9;
    parameter BLOCK_DIM = 9;
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(1),
        .CLK_FREQ(BIT_CYCLES),
        .BAUD_RATE(1),
        .WARPS_PER_CORE(WARPS),
        .THREADS_PER_BLOCK(TPB),
        .BLOCK_DIM(BLOCK_DIM)
    ) dut (
        .clk(clk),
        .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx),
        .led(led)
    );

    always #5 clk = ~clk;

    reg [15:0] prog [0:255];
    reg [7:0]  data [0:8191];
    reg [7:0]  want [0:255];   // 'expect' is a reserved SVA keyword
    reg [7:0]  got  [0:255];
    reg [8*512-1:0] prog_file, data_file, expect_file;
    integer prog_words, data_bytes, n_reply, max_cycles;

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

    integer i, fails, sent;
    initial begin
        if (!$value$plusargs("PROG=%s", prog_file) || !$value$plusargs("DATA=%s", data_file) ||
            !$value$plusargs("EXPECT=%s", expect_file) || !$value$plusargs("PROG_WORDS=%d", prog_words) ||
            !$value$plusargs("DATA_BYTES=%d", data_bytes) || !$value$plusargs("N_REPLY=%d", n_reply)) begin
            $display("RESULT: ERROR - missing plusargs");
            $finish;
        end
        // a harness that compares zero bytes would "pass" anything
        if (prog_words < 1 || prog_words > 256 || data_bytes < 1 || data_bytes > 8191 || n_reply < 2 || n_reply > 256) begin
            $display("RESULT: ERROR - bad sizes prog=%0d data=%0d reply=%0d", prog_words, data_bytes, n_reply);
            $finish;
        end
        $readmemh(prog_file, prog, 0, prog_words - 1);
        $readmemh(data_file, data, 0, data_bytes - 1);
        $readmemh(expect_file, want, 0, n_reply - 1);
        data[data_bytes] = 8'd0;   // pad absorbs the DMA's dropped final byte
        sent = data_bytes + 1;

        repeat (64) @(posedge clk);
        uart_send(prog_words % 256); uart_send(prog_words / 256);
        uart_send(sent % 256);       uart_send(sent / 256);
        for (i = 0; i < prog_words; i = i + 1) begin
            uart_send(prog[i][7:0]); uart_send(prog[i][15:8]);
        end
        for (i = 0; i < sent; i = i + 1) uart_send(data[i]);

        for (i = 0; i < n_reply; i = i + 1) uart_recv(got[i]);

        fails = 0;
        for (i = 0; i < n_reply; i = i + 1)
            if (got[i] !== want[i]) begin
                fails = fails + 1;
                $display("  byte %0d: got %02x expect %02x", i, got[i], want[i]);
            end
        if (fails == 0) $display("RESULT: PASS cycles=%0d", $time / 10);
        else            $display("RESULT: FAIL %0d of %0d bytes wrong", fails, n_reply);
        $finish;
    end

    initial begin
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) max_cycles = 20000000;
        repeat (max_cycles) @(posedge clk);
        $display("RESULT: TIMEOUT after %0d cycles", max_cycles);
        $finish;
    end
endmodule
