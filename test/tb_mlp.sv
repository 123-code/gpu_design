`default_nettype none
`timescale 1ns/1ns
// Parallel-MLP test for the per-lane write path. WARPS=1/TPB=9/BLOCK_DIM=9.
// Streams mlp_parallel.hex + a weight/input payload; each of the 9 lanes computes
// its own neuron y[tid]=2*tid+3 and STOREs it to mem[32+tid] (the per-lane write
// the lsu_write_arbiter unlocks); lane 0 emits the 9 outputs.
// Expected per core: [9][3][5][7][9][11][13][15][17][19].
module tb;
    localparam PROG_WORDS = 50;
    localparam DATA_BYTES = 21;          // mem[0..19] weights/inputs + 1 pad (DMA drops last byte)
    localparam BIT_CYCLES = 16;

    reg clk = 0; reg uart_line = 1'b1; wire uart_tx; wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(DATA_BYTES), .CLK_FREQ(BIT_CYCLES), .BAUD_RATE(1),
        .THREADS_PER_BLOCK(9), .WARPS_PER_CORE(1), .BLOCK_DIM(9)
    ) dut (.clk(clk), .uart_rx_in(uart_line), .uart_tx_out(uart_tx), .led(led));

    always #5 clk = ~clk;

    reg [15:0] prog [0:PROG_WORDS-1];
    reg [7:0]  data [0:DATA_BYTES-1];

    task uart_send(input [7:0] b);
        integer k; begin
            uart_line = 1'b0; repeat (BIT_CYCLES) @(posedge clk);
            for (k=0;k<8;k=k+1) begin uart_line=b[k]; repeat(BIT_CYCLES) @(posedge clk); end
            uart_line = 1'b1; repeat (BIT_CYCLES) @(posedge clk);
        end
    endtask
    task uart_recv(output [7:0] b);
        integer k; begin
            @(negedge uart_tx);
            repeat (BIT_CYCLES + BIT_CYCLES/2) @(posedge clk);
            for (k=0;k<8;k=k+1) begin b[k]=uart_tx; repeat(BIT_CYCLES) @(posedge clk); end
        end
    endtask

    reg [7:0] rx [0:19];
    integer i, t, fails;
    initial begin
        $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/mlp_parallel.hex", prog);
        // payload: in0=2, in1=3, then W[tid]=[tid,1] at mem[2+2t], mem[3+2t]
        for (i=0;i<DATA_BYTES;i=i+1) data[i]=8'd0;
        data[0]=8'd2; data[1]=8'd3;
        for (t=0;t<9;t=t+1) begin data[2+2*t]=t[7:0]; data[3+2*t]=8'd1; end

        repeat (64) @(posedge clk);
        // zero low memory both cores (real BRAM=0; sim=X) incl. output region
        for (i=0;i<64;i=i+1) begin dut.pipe.u_mem.mem[i]=8'd0; dut.pipe.u_mem_1.mem[i]=8'd0; end

        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(DATA_BYTES % 256); uart_send(DATA_BYTES / 256);
        for (i=0;i<PROG_WORDS;i=i+1) begin uart_send(prog[i][7:0]); uart_send(prog[i][15:8]); end
        for (i=0;i<DATA_BYTES;i=i+1) uart_send(data[i]);

        for (i=0;i<20;i=i+1) uart_recv(rx[i]);

        fails = 0;
        // core 0 frame: [9] then 3,5,...,19  (indices 0..9)
        if (rx[0]!==8'd9) begin fails=fails+1; $display("core0 len=%0d (exp 9)",rx[0]); end
        for (t=0;t<9;t=t+1)
            if (rx[1+t]!==(2*t+3)) begin fails=fails+1; $display("core0 y[%0d]=%0d (exp %0d)",t,rx[1+t],2*t+3); end
        // core 1 frame: indices 10..19
        if (rx[10]!==8'd9) begin fails=fails+1; $display("core1 len=%0d (exp 9)",rx[10]); end
        for (t=0;t<9;t=t+1)
            if (rx[11+t]!==(2*t+3)) begin fails=fails+1; $display("core1 y[%0d]=%0d (exp %0d)",t,rx[11+t],2*t+3); end

        $write("reply:"); for (i=0;i<20;i=i+1) $write(" %0d", rx[i]); $write("\n");
        if (fails==0) $display("RESULT: PASS - 9 lanes each computed+wrote their own neuron (y=2*tid+3)");
        else          $display("RESULT: FAIL - %0d mismatch(es)", fails);
        $finish;
    end
    initial begin repeat (4000000) @(posedge clk); $display("RESULT: FAIL - timeout"); $finish; end
endmodule
