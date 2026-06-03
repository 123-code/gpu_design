`timescale 1ns/1ns
// Verify the LSU write path: the GPU stores 42 to data memory, reads it back,
// and emits it. main_memory's write port is driven by the GPU (run mode).
module tb_wtest;
    reg         clk = 0, reset = 1, enable = 0;
    wire [11:0] mem_raddr, mem_waddr;
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
    always #5 clk = ~clk;
    reg [7:0] got_val; reg got = 0;
    always @(posedge clk) if (emit_valid && !got) begin got_val <= emit_data; got <= 1; end
    integer cyc = 0;
    initial begin
        repeat (4) @(negedge clk); reset = 0; enable = 1;
        while (!got && cyc < 5000) begin @(negedge clk); cyc = cyc + 1; end
        @(negedge clk);
        if (!got) $display("RESULT: FAIL - nothing emitted");
        else if (got_val === 8'd42) $display("RESULT: PASS - stored 42, read it back, emitted %0d", got_val);
        else $display("RESULT: FAIL - emitted %0d, expected 42", got_val);
        $finish;
    end
endmodule
