`timescale 1ns/1ns
// Full on-chip pipeline: image preloaded -> GPU runs Conv->Pool->Scatter->FC
// -> emits the predicted digit. Weights/biases baked. Expect digit 7 for image 0.
module tb_mnist_full;
    localparam D = "/Users/joseignacio/tiny-gpu-fpga/software/mnist_data";
    reg clk=0, reset=1, enable=0;
    wire [12:0] mem_raddr, mem_waddr; wire [7:0] mem_rdata, mem_wdata;
    wire mem_we, emit_valid, done; wire [7:0] emit_data;
    gpu uut(.clk(clk),.reset(reset),.enable(enable),.result(),.done(done),
        .debug_core_state(),.debug_instruction(),.operand_a(6'd0),.operand_b(6'd0),
        .mem_raddr(mem_raddr),.mem_rdata(mem_rdata),
        .mem_we(mem_we),.mem_waddr(mem_waddr),.mem_wdata(mem_wdata),
        .emit_valid(emit_valid),.emit_data(emit_data),.emit_ready(1'b1));
    main_memory u_mem(.clk(clk),.we(mem_we),.waddr(mem_waddr),.wdata(mem_wdata),
        .raddr(mem_raddr),.rdata(mem_rdata));
    initial $readmemh({D,"/image0.hex"}, u_mem.mem, 0, 783);
    always #5 clk=~clk;
    reg [7:0] pred; reg got=0;
    always @(posedge clk) if (emit_valid && !got) begin pred<=emit_data; got<=1; end
    integer cyc=0;
    initial begin
        repeat(4) @(negedge clk); reset=0; enable=1;
        while(!got && cyc<5000000) begin @(negedge clk); cyc=cyc+1; end
        @(negedge clk);
        if(!got) $display("RESULT: FAIL - no digit emitted (%0d cyc)", cyc);
        else if(pred===8'd7) $display("RESULT: PASS - FULL on-chip pipeline predicts 7 (%0d cyc)", cyc);
        else $display("RESULT: FAIL - got %0d", pred);
        $finish;
    end
endmodule
