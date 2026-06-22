`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Branch-divergence validation.
//
// Loads software/divergence_kernel.asm over UART and runs it. Each lane branches
// on its OWN threadIdx, so a warp's 4 lanes must take different paths in
// lockstep:
//     lanes 0,1 (threadIdx < 2)  -> branch path -> R3 = 10
//     lanes 2,3 (threadIdx >= 2)  -> stay path   -> R3 = 20
// Correct SIMT divergence => R3 = [10,10,20,20]. If divergence were broken (all
// lanes follow lane 0), every lane would get R3 = 10.
//
// Only thread 0 can emit/store, so per-lane results are read straight out of the
// register files by hierarchical reference.
// ============================================================================
module tb;
    localparam PROG_WORDS = 8;           // software/divergence_kernel.hex length
    localparam BIT_CYCLES = 16;          // = CLK_FREQ/BAUD_RATE below

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(1),
        .CLK_FREQ(BIT_CYCLES),
        .BAUD_RATE(1)
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

    // Per-lane R3 of warp 0 (the divergence result), via hierarchical reference.
    function [7:0] r3(input integer lane);
        case (lane)
            0: r3 = dut.uut.compute_core_0.warp_block[0].thread_block[0].thread_regs.registers[3];
            1: r3 = dut.uut.compute_core_0.warp_block[0].thread_block[1].thread_regs.registers[3];
            2: r3 = dut.uut.compute_core_0.warp_block[0].thread_block[2].thread_regs.registers[3];
            default: r3 = dut.uut.compute_core_0.warp_block[0].thread_block[3].thread_regs.registers[3];
        endcase
    endfunction

    integer i, fails, timeout;
    reg [7:0] exp [0:3];
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/divergence_kernel.hex", prog);
        exp[0] = 8'd10; exp[1] = 8'd10; exp[2] = 8'd20; exp[3] = 8'd20;

        repeat (64) @(posedge clk);

        // header: instr_size (words) LE, data_size = 0
        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(8'd0);             uart_send(8'd0);
        // program: low byte then high byte per word
        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]);
            uart_send(prog[i][15:8]);
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
        for (i = 0; i < 4; i = i + 1) begin
            $display("  lane %0d: R3 = %0d (expected %0d)", i, r3(i), exp[i]);
            if (r3(i) !== exp[i]) fails = fails + 1;
        end

        if (fails == 0)
            $display("RESULT: PASS - lanes diverged correctly: R3 = [%0d,%0d,%0d,%0d]",
                     r3(0), r3(1), r3(2), r3(3));
        else
            $display("RESULT: FAIL - %0d lane(s) wrong (divergence not handled)", fails);
        $finish;
    end

    initial begin
        repeat (2000000) @(posedge clk);
        $display("RESULT: FAIL - global timeout");
        $finish;
    end
endmodule
