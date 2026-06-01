`default_nettype none
`timescale 1ns/1ns

// Proves the GPU is general-purpose: a software dot product (MUL + ADD, no MAC).
//   R3 = 2*3 + 4*5 = 26.   Build with -DKERNEL_HEX="...dotprod_kernel.hex".
module tb;
    reg clk = 0, reset, enable;

    gpu uut (
        .clk(clk), .reset(reset), .enable(enable),
        .operand_a(6'd0), .operand_b(6'd0),
        .mem_rdata(8'd0), .emit_ready(1'b0)
    );

    always #18.5 clk = ~clk;

    reg [7:0] r3;
    initial begin
        enable = 0; reset = 1;
        #100; reset = 0; enable = 1;
        #4000;
        r3 = uut.compute_core_0.thread_block[0].thread_regs.registers[3];
        $display("R3 = %0d (expected 26)", r3);
        if (r3 === 8'd26)
            $display("RESULT: PASS - software dot product via MUL+ADD");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
