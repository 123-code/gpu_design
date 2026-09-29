`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// J++ language features on real hardware: if / max() / constants above 63.
//
// Loads software/jpp_features.hex (compiled from jpp_features.jpp). Each thread
// reads its own id, so the threads of a warp DISAGREE inside max() and the
// first if. The compiler lays both out so the jumping threads land on a SYNC;
// if that layout were wrong, the masked threads would never run their side
// (or would stay masked through the code after it).
//
// Expected, warp 0 threads 0..3:
//   R0 t     = 0, 1, 2, 3
//   R1 big   = 200                  constant above 63 (LDI)
//   R2 m     = 2, 2, 2, 3           max(t, 2), threads disagree
//   R3 r     = 201, 201, 5, 5       if (t < 2), threads disagree
//   R4 after = 8                    one if all skip, one if all enter
//   R5 wide  = 300                  big + 100 (not a truncated ADDI)
// ============================================================================
module tb;
    localparam PROG_WORDS = 37;          // software/jpp_features.hex length
    localparam BIT_CYCLES = 16;

    reg  clk = 0;
    reg  uart_line = 1'b1;
    wire uart_tx;
    wire [5:0] led;

    top #(.PAYLOAD_BYTES(1), .CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1)) dut (
        .clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led));

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

    function [15:0] reg_of(input integer lane, input integer r);
        case (lane)
            0: reg_of = dut.uut.compute_core_0.warp_block[0].thread_block[0].thread_regs.registers[r];
            1: reg_of = dut.uut.compute_core_0.warp_block[0].thread_block[1].thread_regs.registers[r];
            2: reg_of = dut.uut.compute_core_0.warp_block[0].thread_block[2].thread_regs.registers[r];
            default: reg_of = dut.uut.compute_core_0.warp_block[0].thread_block[3].thread_regs.registers[r];
        endcase
    endfunction

    integer i, r, fails, timeout;
    reg [15:0] exp [0:3][0:5];
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/jpp_features.hex", prog);
        for (i = 0; i < 4; i = i + 1) begin
            exp[i][0] = i;
            exp[i][1] = 200;
            exp[i][2] = (i < 3) ? 2 : 3;
            exp[i][3] = (i < 2) ? 201 : 5;
            exp[i][4] = 8;
            exp[i][5] = 300;
        end

        repeat (64) @(posedge clk);

        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(8'd0);             uart_send(8'd0);
        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]);
            uart_send(prog[i][15:8]);
        end

        timeout = 0;
        while (dut.uut.core_0_done !== 1'b1 && timeout < 400000) begin
            @(posedge clk); timeout = timeout + 1;
        end
        repeat (4) @(posedge clk);

        if (dut.uut.core_0_done !== 1'b1) begin
            $display("RESULT: FAIL - core never finished (timeout)");
            $finish;
        end

        fails = 0;
        for (i = 0; i < 4; i = i + 1) begin
            $display("  thread %0d: t=%0d big=%0d m=%0d r=%0d after=%0d wide=%0d",
                     i, reg_of(i,0), reg_of(i,1), reg_of(i,2), reg_of(i,3), reg_of(i,4), reg_of(i,5));
            for (r = 0; r < 6; r = r + 1)
                if (reg_of(i, r) !== exp[i][r]) begin
                    $display("    R%0d = %0d, expected %0d", r, reg_of(i, r), exp[i][r]);
                    fails = fails + 1;
                end
        end

        if (fails == 0)
            $display("RESULT: PASS - if / max / big constants correct on every thread");
        else
            $display("RESULT: FAIL - %0d check(s) wrong", fails);
        $finish;
    end

    initial begin
        repeat (3000000) @(posedge clk);
        $display("RESULT: FAIL - global timeout");
        $finish;
    end
endmodule
