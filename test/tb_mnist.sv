`timescale 1ns/1ns
// Full on-chip FC-classifier sim: the GPU runs mnist_fc.hex against main_memory
// preloaded with image 0's real interleaved (feature,weight) payload, with the
// trained biases in the FC-MAC ROM. Expect the emitted digit == 7.
//
// Build: iverilog -g2012 -s tb_mnist -DKERNEL_HEX='"..../software/mnist_fc.hex"' \
//        test/tb_mnist.sv src/*.sv src/*.v
module tb_mnist;
    reg         clk = 0, reset = 1, enable = 0;
    wire [11:0] mem_raddr;
    wire [7:0]  mem_rdata;
    wire        emit_valid, done;
    wire [7:0]  emit_data;

    gpu uut (
        .clk(clk), .reset(reset), .enable(enable),
        .result(), .done(done),
        .debug_core_state(), .debug_instruction(),
        .operand_a(6'd0), .operand_b(6'd0),
        .mem_raddr(mem_raddr), .mem_rdata(mem_rdata),
        .emit_valid(emit_valid), .emit_data(emit_data),
        .emit_ready(1'b1)                       // ack emits immediately in sim
    );

    main_memory u_mem (
        .clk(clk), .we(1'b0), .waddr(12'd0), .wdata(8'd0),
        .raddr(mem_raddr), .rdata(mem_rdata)
    );

    // Preload the data memory with image 0's FC payload (what the DMA streams on HW).
    initial $readmemh("/Users/joseignacio/tiny-gpu-fpga/software/mnist_data/fc_payload0.hex",
                      u_mem.mem);

    always #5 clk = ~clk;

    reg [7:0] predicted;
    reg       got = 0;
    always @(posedge clk)
        if (emit_valid && !got) begin predicted <= emit_data; got <= 1'b1; end

    // Probe: count FMACs between FARGs, print PC + acc at each FARG.
    integer fmac_cnt = 0;
    always @(posedge clk)
        if (uut.compute_core_0.decoded_fc_mac && uut.compute_core_0.core_state == 3'b110)
            fmac_cnt = fmac_cnt + 1;
    always @(posedge clk)
        if (uut.compute_core_0.decoded_fc_arg && uut.compute_core_0.core_state == 3'b110) begin
            $display("FARG PC=%0d digit=%0d acc=%0d fmac_since_last=%0d",
                     uut.compute_core_0.instruction_address,
                     uut.compute_core_0.u_fc.digit,
                     $signed(uut.compute_core_0.u_fc.acc), fmac_cnt);
            fmac_cnt = 0;
        end

    integer cyc = 0;
    initial begin
        repeat (4) @(negedge clk);
        reset = 0; enable = 1;
        while (!got && cyc < 200000) begin @(negedge clk); cyc = cyc + 1; end
        @(negedge clk);
        if (!got)
            $display("RESULT: FAIL - no digit emitted within %0d cycles", cyc);
        else begin
            $display("emitted digit = %0d (expected 7) after %0d cycles", predicted, cyc);
            if (predicted === 8'd7) $display("RESULT: PASS - on-chip FC classifier predicts 7");
            else                    $display("RESULT: FAIL - got %0d", predicted);
        end
        $finish;
    end
endmodule
