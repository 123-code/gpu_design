`timescale 1ns/1ns
module tb_rearm;
    localparam D = "/Users/joseignacio/tiny-gpu-fpga/software/mnist_data";
    localparam BIT = 16;
    reg clk=0; reg rxin=1; wire txout; wire [5:0] led;
    top #(.PAYLOAD_BYTES(784), .CLK_FREQ(1843200), .BAUD_RATE(115200)) uut (
        .clk(clk), .uart_rx_in(rxin), .uart_tx_out(txout), .led(led));
    always #5 clk=~clk;
    reg [7:0] imgA [0:783]; reg [7:0] imgB [0:783];
    reg [7:0] cm0 [0:675]; reg [7:0] cm1 [0:675];
    integer k, run=0, m0, m1;
    initial $readmemh({D,"/image1.hex"}, imgA);
    initial $readmemh({D,"/image0.hex"}, imgB);
    initial $readmemh({D,"/conv_map1.hex"}, cm1);
    initial $readmemh({D,"/conv_map0.hex"}, cm0);
    task usend(input [7:0] b); integer i; begin
        rxin=0; repeat(BIT) @(posedge clk);
        for(i=0;i<8;i=i+1) begin rxin=b[i]; repeat(BIT) @(posedge clk); end
        rxin=1; repeat(BIT*3) @(posedge clk);
    end endtask
    initial begin #1; for(k=0;k<2048;k=k+1) uut.pipe.u_mem.mem[k]=8'd0; end
    always @(posedge clk) if (uut.gpu_start) begin run=run+1; $display("  gpu_start run %0d (image[100]=%0d, loading=%0b)", run, uut.pipe.u_mem.mem[100], uut.loading); end
    always @(posedge clk) if (uut.emit_valid && uut.emit_ready) $display("  >>> run %0d emit = %0d", run, uut.emit_data);
    always @(uut.loading) $display("    [t=%0t run%0d] loading -> %0b", $time, run, uut.loading);
    always @(posedge clk) if (uut.done) $display("    [t=%0t run%0d] gpu done", $time, run);
    initial begin
        repeat(50) @(posedge clk);
        $display("--- image1 (expect 2) ---");
        for(k=0;k<784;k=k+1) usend(imgA[k]);
        repeat(700000) @(posedge clk);
        $display("--- image0 (expect 7) ---");
        for(k=0;k<784;k=k+1) usend(imgB[k]);
        repeat(700000) @(posedge clk);
        // after run2: does the conv map match image0 (recomputed) or image1 (stale)?
        m0=0; m1=0;
        for(k=0;k<676;k=k+1) begin
            if (uut.pipe.u_mem.mem[1024+k]===cm0[k]) m0=m0+1;
            if (uut.pipe.u_mem.mem[1024+k]===cm1[k]) m1=m1+1;
        end
        $display("after run2: conv map matches image0=%0d/676  image1(stale)=%0d/676", m0, m1);
        $finish;
    end
endmodule
