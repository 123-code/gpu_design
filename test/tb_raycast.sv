`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// The J++ raycaster (software/raycast.jpp) on the board's configuration:
// 2 cores x 1 warp x 9 threads, one thread per screen column.
//
// Frame 1 streams the kernel, tables, map and a pose. Frame 2 streams only a
// new pose with instr_size = 0, which is every frame after the first on the
// board: the program and tables must survive in BRAM and the DMA must re-arm.
// Each reply (per core: a length byte + 36 column bytes) must match the
// bit-exact reference from raycast.py --sim, byte for byte, and the HDMI
// capture (src/hdmi.sv) must hold the same 72 columns as its newest frame.
// ============================================================================
module tb;
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(1), .CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1),
        .WARPS_PER_CORE(1), .THREADS_PER_BLOCK(9), .BLOCK_DIM(9)
    ) dut (.clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led));

    always #5 clk = ~clk;

    reg [15:0] sizes [0:3];    // program words, frame-1 bytes, frame-2 bytes, reply bytes
    reg [15:0] prog  [0:255];
    reg [7:0]  data  [0:8191];
    reg [7:0]  pose2 [0:15];
    reg [7:0]  want1 [0:255];
    reg [7:0]  want2 [0:255];
    reg [7:0]  got;

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

    // Render time: run start -> core 0's first emitted byte (all 4 waves done).
    time t_start = 0, t_emit = 0;
    always @(posedge dut.pipe.gpu_start) begin t_start = $time; t_emit = 0; end
    always @(posedge dut.uut.emit_valid) if (t_emit == 0) t_emit = $time;

    // The HDMI scanout's newest-frame buffer must hold the reply's columns.
    task check_hdmi(input integer which, output integer wrong);
        integer col, n;
        reg [1:0] b;
        reg [7:0] want;
        begin
            n = sizes[3] / 2 - 1;                        // columns per core
            b = dut.u_hdmi.done[1] ? 2'd1 : dut.u_hdmi.done[2] ? 2'd2 : 2'd0;
            wrong = 0;
            for (col = 0; col < 2 * n; col = col + 1) begin
                want = which == 1 ? want1[col < n ? col + 1 : col + 2] : want2[col < n ? col + 1 : col + 2];
                if (dut.u_hdmi.colmem[{b, col[6:0]}] !== want) wrong = wrong + 1;
            end
            $display("  frame %0d: HDMI buffer %0d/%0d columns wrong", which, wrong, 2 * n);
        end
    endtask

    integer i, bad1 = 0, bad2 = 0, hbad1, hbad2;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/raycast.sizes.hex", sizes);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/raycast.hex", prog);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/raycast.data.hex", data);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/raycast.frame2.hex", pose2);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/raycast.expect1.hex", want1);
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/build/raycast.expect2.hex", want2);

        // ---- frame 1: kernel + tables + map + pose ----
        repeat (64) @(posedge clk);
        uart_send(sizes[0][7:0]); uart_send(sizes[0][15:8]);
        uart_send(sizes[1][7:0]); uart_send(sizes[1][15:8]);
        for (i = 0; i < sizes[0]; i = i + 1) begin
            uart_send(prog[i][7:0]); uart_send(prog[i][15:8]);
        end
        for (i = 0; i < sizes[1]; i = i + 1) uart_send(data[i]);
        for (i = 0; i < sizes[3]; i = i + 1) begin
            uart_recv(got);
            if (got !== want1[i]) begin
                if (bad1 < 5) $display("  frame 1 byte %0d = %02h, expected %02h", i, got, want1[i]);
                bad1 = bad1 + 1;
            end
        end
        $display("  frame 1: %0d/%0d bytes wrong, render %0d cycles", bad1, sizes[3], (t_emit - t_start) / 10);
        check_hdmi(1, hbad1);

        // ---- frame 2: pose only, program and tables stay in BRAM ----
        wait (dut.uut.done);
        repeat (64) @(posedge clk);
        uart_send(8'd0); uart_send(8'd0);
        uart_send(sizes[2][7:0]); uart_send(sizes[2][15:8]);
        for (i = 0; i < sizes[2]; i = i + 1) uart_send(pose2[i]);
        for (i = 0; i < sizes[3]; i = i + 1) begin
            uart_recv(got);
            if (got !== want2[i]) begin
                if (bad2 < 5) $display("  frame 2 byte %0d = %02h, expected %02h", i, got, want2[i]);
                bad2 = bad2 + 1;
            end
        end
        $display("  frame 2: %0d/%0d bytes wrong, render %0d cycles", bad2, sizes[3], (t_emit - t_start) / 10);
        check_hdmi(2, hbad2);

        if (bad1 == 0 && bad2 == 0 && hbad1 == 0 && hbad2 == 0)
            $display("RESULT: PASS - raycaster matches the reference on both frames, HDMI got them");
        else
            $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        repeat (60000000) @(posedge clk);
        $display("RESULT: FAIL - global timeout");
        $finish;
    end
endmodule
