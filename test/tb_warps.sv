`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Multi-warp launch-bounds validation.
//
// Loads software/tid_demo.asm (TID R1; RET) over UART and runs it with
// BLOCK_DIM = 8, so the core launches BOTH warps over 8 distinct threads:
//     warp 0 lanes -> threadIdx 0,1,2,3
//     warp 1 lanes -> threadIdx 4,5,6,7
// This is the proof that the two warps no longer redundantly run the same
// 4-thread kernel: each lane holds its own GLOBAL threadIdx (0..7), and the
// %blockDim register (R14) reports 8.
//
// Only thread 0 can emit/store, so per-lane results are read straight out of
// the register files by hierarchical reference.
// ============================================================================
module tb;
    localparam PROG_WORDS = 2;           // software/tid_demo.hex length
    localparam BIT_CYCLES = 16;          // = CLK_FREQ/BAUD_RATE below

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(1),
        .CLK_FREQ(BIT_CYCLES),
        .BAUD_RATE(1),
        .BLOCK_DIM(8)            // launch both warps (8 threads)
    ) dut (
        .clk(clk),
        .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx),
        .led(led)
    );

    always #5 clk = ~clk;

    reg [15:0] prog [0:PROG_WORDS-1];

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

    // Per-lane R1 (threadIdx) across BOTH warps, via hierarchical reference.
    function [7:0] tid(input integer warp, input integer lane);
        case ({warp[0], lane[1:0]})
            3'b000: tid = dut.uut.compute_core_0.warp_block[0].thread_block[0].thread_regs.registers[1];
            3'b001: tid = dut.uut.compute_core_0.warp_block[0].thread_block[1].thread_regs.registers[1];
            3'b010: tid = dut.uut.compute_core_0.warp_block[0].thread_block[2].thread_regs.registers[1];
            3'b011: tid = dut.uut.compute_core_0.warp_block[0].thread_block[3].thread_regs.registers[1];
            3'b100: tid = dut.uut.compute_core_0.warp_block[1].thread_block[0].thread_regs.registers[1];
            3'b101: tid = dut.uut.compute_core_0.warp_block[1].thread_block[1].thread_regs.registers[1];
            3'b110: tid = dut.uut.compute_core_0.warp_block[1].thread_block[2].thread_regs.registers[1];
            default: tid = dut.uut.compute_core_0.warp_block[1].thread_block[3].thread_regs.registers[1];
        endcase
    endfunction

    // %blockDim (R14) of warp 0 lane 0 — should report the launch size, 8.
    wire [7:0] block_dim =
        dut.uut.compute_core_0.warp_block[0].thread_block[0].thread_regs.registers[14];

    integer w, l, g, fails, timeout;
    reg [7:0] got;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/tid_demo.hex", prog);

        repeat (64) @(posedge clk);

        // header: instr_size (words) LE, data_size = 0
        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(8'd0);             uart_send(8'd0);
        // program: low byte then high byte per word
        for (g = 0; g < PROG_WORDS; g = g + 1) begin
            uart_send(prog[g][7:0]);
            uart_send(prog[g][15:8]);
        end

        // wait for core 0 to finish (both warps RET)
        timeout = 0;
        while (dut.uut.core_0_done !== 1'b1 && timeout < 200000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        repeat (4) @(posedge clk);

        if (dut.uut.core_0_done !== 1'b1) begin
            $display("RESULT: FAIL - core never finished (timeout)");
            $finish;
        end

        fails = 0;
        for (w = 0; w < 2; w = w + 1) begin
            for (l = 0; l < 4; l = l + 1) begin
                g   = w * 4 + l;          // expected global threadIdx
                got = tid(w, l);
                $display("  warp %0d lane %0d: threadIdx = %0d (expected %0d)", w, l, got, g);
                if (got !== g[7:0]) fails = fails + 1;
            end
        end

        $display("  blockDim (R14) = %0d (expected 8)", block_dim);
        if (block_dim !== 8'd8) fails = fails + 1;

        if (fails == 0)
            $display("RESULT: PASS - both warps ran DISTINCT global threadIdx 0..7 (blockDim=8)");
        else
            $display("RESULT: FAIL - %0d mismatch(es) (warps not launched with distinct IDs)", fails);
        $finish;
    end

    initial begin
        repeat (2000000) @(posedge clk);
        $display("RESULT: FAIL - global timeout");
        $finish;
    end
endmodule
