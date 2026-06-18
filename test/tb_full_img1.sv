`timescale 1ns/1ns
// Full on-chip pipeline, dual core: a DIFFERENT image is preloaded into each
// core's memory copy; each core runs Conv->Pool->Scatter->FC on its own image.
// Expected 8-byte emit stream: [digit0][cycles0 x3][digit1][cycles1 x3].
// Copy 0 gets image1 (digit 2), copy 1 gets image0 (digit 7).
module tb_full_img1;
    localparam D = "/Users/joseignacio/tiny-gpu-fpga/software/mnist_data";
    reg clk=0, reset=1, enable=0;
    wire [12:0] mem_raddr, mem_waddr; wire [7:0] mem_rdata, mem_wdata;
    wire [12:0] mem_raddr_1, mem_waddr_1; wire [7:0] mem_rdata_1, mem_wdata_1;
    wire mem_we, mem_we_1, emit_valid, done; wire [7:0] emit_data;
    gpu uut(.clk(clk),.reset(reset),.enable(enable),.result(),.done(done),
        .debug_core_state(),.debug_instruction(),.operand_a(6'd0),.operand_b(6'd0),
        .mem_raddr(mem_raddr),.mem_rdata(mem_rdata),
        .mem_we(mem_we),.mem_waddr(mem_waddr),.mem_wdata(mem_wdata),
        .mem_raddr_1(mem_raddr_1),.mem_rdata_1(mem_rdata_1),
        .mem_we_1(mem_we_1),.mem_waddr_1(mem_waddr_1),.mem_wdata_1(mem_wdata_1),
        .emit_valid(emit_valid),.emit_data(emit_data),.emit_ready(1'b1));
    main_memory u_mem(.clk(clk),.we(mem_we),.waddr(mem_waddr),.wdata(mem_wdata),
        .raddr(mem_raddr),.rdata(mem_rdata));
    main_memory u_mem_1(.clk(clk),.we(mem_we_1),.waddr(mem_waddr_1),.wdata(mem_wdata_1),
        .raddr(mem_raddr_1),.rdata(mem_rdata_1));
    initial $readmemh({D,"/image1.hex"}, u_mem.mem,   0, 783);
    initial $readmemh({D,"/image0.hex"}, u_mem_1.mem, 0, 783);
    always #5 clk=~clk;

    // With emit_ready tied high, every cycle emit_valid is up is one byte.
    reg [7:0] rx [0:7]; integer n=0;
    always @(posedge clk) if (emit_valid && n<8) begin rx[n]=emit_data; n=n+1; end

    integer cyc=0, cnt0, cnt1;
    initial begin
        repeat(4) @(negedge clk); reset=0; enable=1;
        while(!(n==8 && done) && cyc<5000000) begin @(negedge clk); cyc=cyc+1; end
        @(negedge clk);
        cnt0 = (rx[1]<<16)|(rx[2]<<8)|rx[3];
        cnt1 = (rx[5]<<16)|(rx[6]<<8)|rx[7];
        if(n<8) $display("RESULT: FAIL - only %0d of 8 bytes emitted (%0d cyc)", n, cyc);
        else if(!done) $display("RESULT: FAIL - 8 bytes but gpu done never rose");
        else if(rx[0]!==8'd2) $display("RESULT: FAIL - core 0 predicted %0d, expected 2", rx[0]);
        else if(rx[4]!==8'd7) $display("RESULT: FAIL - core 1 predicted %0d, expected 7", rx[4]);
        else $display("RESULT: PASS - core0=2 (%0d cyc), core1=7 (%0d cyc), both done", cnt0, cnt1);
        $finish;
    end
endmodule
