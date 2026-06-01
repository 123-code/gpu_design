`default_nettype none
`timescale 1ns/1ns

// Self-checking testbench for the 3x3 MAC instruction.
// Loads conv_kernel.hex (compile with -DKERNEL_HEX="...conv_kernel.hex").
//   9 pixels=30, 9 weights=20 -> sum=5400 -> 5400>>8 = 21  => R3 must be 21.
module tb;
    reg clk, reset, enable;

    gpu uut (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .operand_a(6'd0),   // unused by the conv kernel
        .operand_b(6'd0),
        .mem_rdata(8'd0),   // no LDR in this kernel
        .emit_ready(1'b0)
    );

    always #18.5 clk = ~clk;

    initial begin
        clk = 0; enable = 0; reset = 1;
        #100; reset = 0; enable = 1;
        #15000;   // ~22 instructions x 8 states; plenty of slack

        begin : check
            reg [7:0] r3;
            reg core_done;
            r3 = uut.compute_core_0.thread_block[0].thread_regs.registers[3];
            core_done = uut.core_0_done;
            $display("R3 (3x3 MAC result) = %0d (expected 21)", r3);
            $display("core_0_done          = %0b (expected 1)", core_done);
            if (r3 === 8'd21 && core_done === 1'b1)
                $display("RESULT: PASS - 3x3 MAC computed 21");
            else
                $display("RESULT: FAIL");
        end
        $finish;
    end
endmodule
