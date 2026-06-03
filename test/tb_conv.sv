`timescale 1ns/1ns
// Stage 1: verify the on-chip CONV map matches mnist_ref.py for image 0.
module tb_conv;
    localparam D = "/Users/joseignacio/tiny-gpu-fpga/software/mnist_data";
    reg         clk = 0, reset = 1, enable = 0;
    wire [12:0] mem_raddr, mem_waddr;
    wire [7:0]  mem_rdata, mem_wdata;
    wire        mem_we, emit_valid, done;
    wire [7:0]  emit_data;

    gpu uut (
        .clk(clk), .reset(reset), .enable(enable),
        .result(), .done(done), .debug_core_state(), .debug_instruction(),
        .operand_a(6'd0), .operand_b(6'd0),
        .mem_raddr(mem_raddr), .mem_rdata(mem_rdata),
        .mem_we(mem_we), .mem_waddr(mem_waddr), .mem_wdata(mem_wdata),
        .emit_valid(emit_valid), .emit_data(emit_data), .emit_ready(1'b1)
    );
    main_memory u_mem (
        .clk(clk), .we(mem_we), .waddr(mem_waddr), .wdata(mem_wdata),
        .raddr(mem_raddr), .rdata(mem_rdata)
    );
    initial $readmemh({D, "/image0.hex"}, u_mem.mem, 0, 783);   // image at addr 0

    reg [7:0] cref [0:675];
    initial $readmemh({D, "/conv_map0.hex"}, cref);

    always #5 clk = ~clk;
    integer cyc = 0, k, errs = 0;
    initial begin
        repeat (4) @(negedge clk); reset = 0; enable = 1;
        while (!done && cyc < 2000000) begin @(negedge clk); cyc = cyc + 1; end
        @(negedge clk);
        if (!done) begin $display("RESULT: FAIL - conv did not finish (%0d cyc)", cyc); $finish; end
        for (k = 0; k < 676; k = k + 1)
            if (u_mem.mem[1024 + k] !== cref[k]) begin
                if (errs < 8) $display("  mismatch @%0d: got %0d, ref %0d", k, u_mem.mem[1024+k], cref[k]);
                errs = errs + 1;
            end
        if (errs == 0) $display("RESULT: PASS - conv map matches reference (676/676) in %0d cyc", cyc);
        else           $display("RESULT: FAIL - %0d/676 conv pixels wrong", errs);
        $finish;
    end
endmodule
