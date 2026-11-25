`default_nettype none
`timescale 1ns/1ns

// Clusters: a 2-block cluster launch on the 2 cores (software/gen_cluster_test.py).
//   - DSMEM: each block stores into the PEER's shared memory, CBARs, then
//     reads its own shared memory (the peer's values) and the peer's (its
//     own values, by a DSMEM load)
//   - MMA2: each core stages only its half of B; the tensor core fetches the
//     other half from the peer and computes 4 rows x 8 columns
// Checks both cores' data memory against the reference, byte for byte.
//
//     +prefix=software/build/cluster_s8
module tb;
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(.CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1), .BLOCK_DIM(4)) dut (
        .clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led)
    );
    always #5 clk = ~clk;

    `include "test/host_uart.svh"

    reg [7:0] exp0 [0:159];
    reg [7:0] exp1 [0:159];
    reg [8*256-1:0] prefix;
    integer i, c, a, fails, ndata;
    reg [7:0] got, want;

    initial begin
        if (!$value$plusargs("prefix=%s", prefix)) prefix = "software/build/cluster_s8";
        for (i = 0; i < 256; i = i + 1) host_prog[i] = 16'hxxxx;
        for (i = 0; i < 8192; i = i + 1) host_data[i] = 8'hxx;
        $readmemh({prefix, ".hex"}, host_prog);
        $readmemh({prefix, ".data.hex"}, host_data);
        $readmemh({prefix, ".expect0.hex"}, exp0);
        $readmemh({prefix, ".expect1.hex"}, exp1);
        ndata = 0;
        while (ndata < 8192 && ^host_data[ndata] !== 1'bx) ndata = ndata + 1;

        repeat (64) @(posedge clk);
        for (i = 0; i < 512; i = i + 1) begin
            dut.pipe.u_mem.mem[i] = 8'd0; dut.pipe.u_mem_1.mem[i] = 8'd0;
        end
        send_frame_ex(prog_len(256), ndata, 2, 2);     // grid 2, cluster launch
        @(posedge dut.done);
        repeat (20) @(posedge clk);

        fails = 0;
        for (c = 0; c < 2; c = c + 1)
            for (i = 0; i < 160; i = i + 1) begin
                a = (i < 32) ? 160 + i : 256 + (i - 32);
                got  = c ? dut.pipe.u_mem_1.mem[a] : dut.pipe.u_mem.mem[a];
                want = c ? exp1[i] : exp0[i];
                if (got !== want) begin
                    if (fails < 12)
                        $display("  core %0d mem[%0d] (%s): got %02x, want %02x", c, a,
                                 i < 16 ? "own smem" : i < 32 ? "DSMEM load" : "MMA2 D", got, want);
                    fails = fails + 1;
                end
            end

        if (fails == 0)
            $display("RESULT: PASS - %0s: DSMEM stores/loads, CBAR and MMA2 correct on both ranks", prefix);
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
