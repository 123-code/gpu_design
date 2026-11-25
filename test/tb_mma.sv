`default_nettype none
`timescale 1ns/1ns

// Tensor core end to end: software/gen_mma_test.py writes a kernel, a data
// payload and the bytes the kernel must leave in main memory (computed by the
// bit-exact model in software/tc_ref.py). This bench streams the kernel and
// payload in over the UART, runs one block per core, and compares both cores'
// result regions byte for byte.
//
//     +prefix=software/build/mma_s8   (files: .hex .data.hex .expect.hex)
//     +need_overlap   also require cycles where the copy engine and the
//                     tensor core were busy at once (the --tma kernels)
module tb;
    localparam BIT_CYCLES = 16;
    localparam RESULT_BASE = 256;
    localparam NEXPECT = 144;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    // One warp of 4 lanes per block (warp 1 launches DONE)
    top #(.CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1), .BLOCK_DIM(4)) dut (
        .clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led)
    );
    always #5 clk = ~clk;

    `include "test/host_uart.svh"

    reg [7:0] expect_b [0:NEXPECT-1];
    reg [8*256-1:0] prefix;
    integer i, c, fails, ndata;
    reg [7:0] got;

    // Cycles in which core 0's copy engine streamed data while its tensor
    // core computed: the async overlap TMA exists for.
    integer overlap = 0, tc_cycles = 0, kcycles = 0;
    always @(posedge clk) begin
        if (dut.gpu_enable && !dut.done) kcycles = kcycles + 1;   // kernel run time
        if (dut.uut.compute_core_0.tc_busy) tc_cycles = tc_cycles + 1;
        if (dut.uut.compute_core_0.tc_busy && dut.uut.compute_core_0.tma_busy) overlap = overlap + 1;
    end

    initial begin
        if (!$value$plusargs("prefix=%s", prefix)) prefix = "software/build/mma_s8";
        for (i = 0; i < 256; i = i + 1) host_prog[i] = 16'hxxxx;
        for (i = 0; i < 8192; i = i + 1) host_data[i] = 8'hxx;
        $readmemh({prefix, ".hex"}, host_prog);
        $readmemh({prefix, ".data.hex"}, host_data);
        $readmemh({prefix, ".expect.hex"}, expect_b);
        ndata = 0;
        while (ndata < 8192 && ^host_data[ndata] !== 1'bx) ndata = ndata + 1;

        repeat (64) @(posedge clk);
        for (i = 0; i < 512; i = i + 1) begin
            dut.pipe.u_mem.mem[i] = 8'd0; dut.pipe.u_mem_1.mem[i] = 8'd0;
        end
        send_frame(prog_len(256), ndata, 0);
        @(posedge dut.done);
        repeat (20) @(posedge clk);

        fails = 0;
        for (c = 0; c < 2; c = c + 1)
            for (i = 0; i < NEXPECT; i = i + 1) begin
                got = c ? dut.pipe.u_mem_1.mem[RESULT_BASE + i] : dut.pipe.u_mem.mem[RESULT_BASE + i];
                if (got !== expect_b[i]) begin
                    if (fails < 12)
                        $display("  core %0d byte %0d (%s): got %02x, want %02x", c, i,
                                 i < 128 ? "D" : "TLDQ", got, expect_b[i]);
                    fails = fails + 1;
                end
            end

        $display("kernel %0d cycles; tensor core busy %0d, %0d of them overlapped with a TMA copy",
                 kcycles, tc_cycles, overlap);
        if ($test$plusargs("need_overlap") && overlap == 0) begin
            fails = fails + 1;
            $display("  no TMA/MMA overlap");
        end
        if (fails == 0)
            $display("RESULT: PASS - %0s: 3 MMAs + TLD/TLDQ match the reference on both cores", prefix);
        else
            $display("RESULT: FAIL - %0s: %0d byte(s) differ", prefix, fails);
        $finish;
    end

    initial begin
        repeat (3000000) @(posedge clk);
        $display("RESULT: FAIL - timeout");
        $finish;
    end
endmodule
