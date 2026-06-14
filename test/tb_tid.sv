`default_nettype none
`timescale 1ns/1ns

// SIMT thread-ID test. Streams a small payload to trigger the DMA -> GPU, then
// runs a kernel that reads threadIdx (TID R1) and, for divergent_load, also does
// LDR R2,[R1]. We then peek the 4 lanes' register files and confirm they hold
// DISTINCT per-lane values — the proof that real SIMT divergence now works.
//
//   tid_demo.hex                 : expect R1 = 0,1,2,3 across lanes
//   divergent_load.hex (-DCHECK_LOAD): also expect R2 = mem[threadIdx] per lane
//
// Build with -DKERNEL_HEX="...<kernel>.hex" (and -DCHECK_LOAD for divergent_load).
module tb;
    // 4 data bytes (mem[0..3]) + 1 padding byte. The DMA drops its FINAL write
    // (its mem_we pulse coincides with loading->GPU handoff in data_pipeline.sv),
    // so the pad byte absorbs that drop and mem[0..3] are all committed.
    localparam PAYLOAD    = 5;
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
    reg [7:0] r1 [0:3];
    reg [7:0] r2 [0:3];
    reg ok;

    initial begin
        repeat (40) @(posedge clk);    // let the power-on reset clear

        // Stream a tiny payload (becomes mem[0..3] for the divergent-load kernel).
        for (i = 0; i < PAYLOAD; i = i + 1) begin
            sent[i] = (i * 53 + 17) & 8'hFF;   // 17, 70, 123, 176 (distinct)
            uart_send(sent[i]);
        end

        // Wait for the DMA to wake the GPU and the kernel to finish.
        t = 0;
        while (t < 20000 && dut.done !== 1'b1) begin @(posedge clk); t = t + 1; end

        // Peek each lane's R1 (threadIdx) and R2 (loaded element).
        r1[0] = dut.uut.compute_core_0.thread_block[0].thread_regs.registers[1];
        r1[1] = dut.uut.compute_core_0.thread_block[1].thread_regs.registers[1];
        r1[2] = dut.uut.compute_core_0.thread_block[2].thread_regs.registers[1];
        r1[3] = dut.uut.compute_core_0.thread_block[3].thread_regs.registers[1];
        r2[0] = dut.uut.compute_core_0.thread_block[0].thread_regs.registers[2];
        r2[1] = dut.uut.compute_core_0.thread_block[1].thread_regs.registers[2];
        r2[2] = dut.uut.compute_core_0.thread_block[2].thread_regs.registers[2];
        r2[3] = dut.uut.compute_core_0.thread_block[3].thread_regs.registers[2];

        $display("done=%0b after %0d cycles", dut.done, t);
        $display("R1 per lane = %0d %0d %0d %0d   (expect 0 1 2 3)",
                 r1[0], r1[1], r1[2], r1[3]);

        ok = (dut.done === 1'b1) &&
             (r1[0] === 8'd0) && (r1[1] === 8'd1) &&
             (r1[2] === 8'd2) && (r1[3] === 8'd3);

`ifdef CHECK_LOAD
        $display("R2 per lane = %02x %02x %02x %02x   (expect %02x %02x %02x %02x)",
                 r2[0], r2[1], r2[2], r2[3], sent[0], sent[1], sent[2], sent[3]);
        ok = ok && (r2[0] === sent[0]) && (r2[1] === sent[1]) &&
                   (r2[2] === sent[2]) && (r2[3] === sent[3]);
`endif

        if (ok)
            $display("RESULT: PASS - 4 lanes hold DISTINCT per-thread values (real SIMT)");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
