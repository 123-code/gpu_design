`timescale 1ns/1ns
// Stage 2: verify on-chip CONV (676) and POOL (169) maps vs mnist_ref.py (image 0).
module tb_pool;
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
    reg [7:0] cmap [0:675]; reg [7:0] pmap [0:168];
    initial $readmemh({D,"/conv_map0.hex"}, cmap);
    initial $readmemh({D,"/pool_map0.hex"}, pmap);
    always #5 clk=~clk;
    integer cyc=0,k,ec=0,ep=0;
    initial begin
        repeat(4) @(negedge clk); reset=0; enable=1;
        while(!done && cyc<3000000) begin @(negedge clk); cyc=cyc+1; end
        @(negedge clk);
        if(!done) begin $display("RESULT: FAIL - timeout %0d",cyc); $finish; end
        for(k=0;k<676;k=k+1) if(u_mem.mem[1024+k]!==cmap[k]) ec=ec+1;
        for(k=0;k<169;k=k+1) if(u_mem.mem[1700+k]!==pmap[k]) begin
            if(ep<8) $display("  pool mismatch @%0d: got %0d ref %0d",k,u_mem.mem[1700+k],pmap[k]); ep=ep+1; end
        $display("conv errs=%0d  pool errs=%0d  (%0d cyc)",ec,ep,cyc);
        if(ec==0 && ep==0) $display("RESULT: PASS - conv+pool match reference");
        else $display("RESULT: FAIL");
        $finish;
    end
endmodule
