`default_nettype none
`timescale 1ns/1ns

// Shared memory (LDS/STS) + block barrier (BAR), end to end.
//
// Runs software/smem_kernel.asm (2 blocks, one per core, 2 warps x 4 lanes):
// every thread writes a 16-bit value to shared memory, barriers, and reads its
// neighbour's slot (crossing the warp boundary at tid 3 and 7). Each core's
// main memory then holds, at 32 + 2*tid, the neighbour's value. Checked for
// both cores (blockIdx 0 and 1 make the values differ).
//
// Then the same kernel WITHOUT the BAR (smem_nobar_kernel.asm) is run, and
// must get some lanes wrong: proof the barrier is what orders the accesses.
module tb;
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(.CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1)) dut (
        .clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led)
    );
    always #5 clk = ~clk;

    `include "test/host_uart.svh"

    function automatic [15:0] v(input integer tid, input integer bid);
        v = 1000*tid + bid + 7;
    endfunction

    // Wrong lanes (over both cores) of the last run
    function automatic integer check(input integer verbose);
        integer t, b, bad;
        reg [15:0] got, want;
        begin
            bad = 0;
            for (b = 0; b < 2; b = b + 1)
                for (t = 0; t < 8; t = t + 1) begin
                    want = v((t + 1) % 8, b);
                    if (b == 0) got = {dut.pipe.u_mem.mem[33+2*t],   dut.pipe.u_mem.mem[32+2*t]};
                    else        got = {dut.pipe.u_mem_1.mem[33+2*t], dut.pipe.u_mem_1.mem[32+2*t]};
                    if (got !== want) begin
                        bad = bad + 1;
                        if (verbose) $display("  block %0d tid %0d: got %0d, want %0d", b, t, got, want);
                    end
                end
            check = bad;
        end
    endfunction

    task automatic run(input [8*64-1:0] hex);
        integer i;
        begin
            for (i = 0; i < 256; i = i + 1) host_prog[i] = 16'hxxxx;
            $readmemh(hex, host_prog);
            for (i = 0; i < 64; i = i + 1) begin
                dut.pipe.u_mem.mem[i] = 8'd0; dut.pipe.u_mem_1.mem[i] = 8'd0;
            end
            for (i = 0; i < 256; i = i + 1) begin
                dut.uut.compute_core_0.u_smem.mem[i] = 32'd0;
                dut.uut.compute_core_1.u_smem.mem[i] = 32'd0;
            end
            send_frame(prog_len(256), 0, 0);
            @(posedge dut.done);
            repeat (20) @(posedge clk);
        end
    endtask

    integer bad_bar, bad_nobar;
    initial begin
        repeat (64) @(posedge clk);
        run("software/smem_kernel.hex");
        bad_bar = check(1);
        run("software/smem_nobar_kernel.hex");
        bad_nobar = check(0);
        $display("with BAR: %0d/16 lanes wrong; without BAR: %0d/16 lanes wrong", bad_bar, bad_nobar);
        if (bad_bar == 0 && bad_nobar > 0)
            $display("RESULT: PASS - shared memory + BAR: every lane read its neighbour across warps");
        else if (bad_bar != 0)
            $display("RESULT: FAIL - %0d lane(s) wrong with the barrier", bad_bar);
        else
            $display("RESULT: FAIL - the no-barrier run was also correct, so the test proves nothing");
        $finish;
    end

    initial begin
        repeat (2000000) @(posedge clk);
        $display("RESULT: FAIL - timeout");
        $finish;
    end
endmodule
