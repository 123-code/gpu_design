`default_nettype none
`timescale 1ns/1ns

// Full sliding-window convolution over a 28x28 image.
//   Stream 9 weights (addr 0..8) + 784 image bytes (addr 9..792), run conv_full.hex.
//   The GPU slides a 3x3 window over the image, emitting each result byte over
//   UART (STR -> memory-mapped TX). We capture all 26*26 = 676 emitted bytes and
//   compare to a reference convolution computed here (matching the MAC's
//   signed multiply + ReLU + >>8 quantize).
//
// Build with -DKERNEL_HEX="...conv_full.hex".
module tb;
    localparam PAYLOAD    = 793;
    localparam BIT_CYCLES = 16;
    localparam OW         = 26;        // output width/height
    localparam NOUT       = OW * OW;   // 676

    reg clk = 0;
    reg uart_line = 1'b1;
    wire uart_tx_out;
    wire [5:0] led;

    top #(.PAYLOAD_BYTES(PAYLOAD), .CLK_FREQ(16), .BAUD_RATE(1)) dut (
        .clk(clk), .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx_out), .led(led)
    );

    always #5 clk = ~clk;

    // Source data.
    reg [7:0]        image  [0:27][0:27];
    reg signed [7:0] weight [0:2][0:2];
    reg [7:0]        ref_out [0:NOUT-1];

    // Capture each emitted byte the moment top launches it onto the UART.
    reg [7:0] cap [0:NOUT-1];
    integer ncap = 0;
    always @(posedge clk)
        if (dut.tx_start && ncap < NOUT) begin
            cap[ncap] = dut.emit_data;
            ncap = ncap + 1;
        end

    task uart_send(input [7:0] b);
        integer k;
        begin
            uart_line = 1'b0; repeat (BIT_CYCLES) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_line = b[k]; repeat (BIT_CYCLES) @(posedge clk);
            end
            uart_line = 1'b1; repeat (BIT_CYCLES) @(posedge clk);
        end
    endtask

    integer ir, ic, orr, oc, dr, dc, t, mism, idx;
    integer signed sum;
    reg [7:0] q;
    initial begin
        // Build image + weights (varied; weights include negatives -> ReLU exercised).
        for (ir = 0; ir < 28; ir = ir + 1)
            for (ic = 0; ic < 28; ic = ic + 1)
                image[ir][ic] = (ir*3 + ic*5 + 10) & 8'hFF;
        weight[0][0]= 1; weight[0][1]= 2; weight[0][2]= 1;
        weight[1][0]= 0; weight[1][1]= 0; weight[1][2]= 0;
        weight[2][0]=-1; weight[2][1]=-2; weight[2][2]=-1;

        // Reference convolution (matches mac_array_3x3 quantize semantics).
        for (orr = 0; orr < OW; orr = orr + 1)
          for (oc = 0; oc < OW; oc = oc + 1) begin
              sum = 0;
              for (dr = 0; dr < 3; dr = dr + 1)
                for (dc = 0; dc < 3; dc = dc + 1)
                    sum = sum + $signed({1'b0, image[orr+dr][oc+dc]}) * weight[dr][dc];
              if (sum < 0)                q = 8'd0;
              else if ((sum >>> 8) > 255) q = 8'd255;
              else                        q = sum[15:8];
              ref_out[orr*OW + oc] = q;
          end

        // Stream: 9 weights (addr 0..8), then 784 image bytes (addr 9..792).
        repeat (40) @(posedge clk);
        for (dr = 0; dr < 3; dr = dr + 1)
          for (dc = 0; dc < 3; dc = dc + 1)
              uart_send(weight[dr][dc]);            // signed -> raw byte
        for (ir = 0; ir < 28; ir = ir + 1)
          for (ic = 0; ic < 28; ic = ic + 1)
              uart_send(image[ir][ic]);

        // Wait until all 676 outputs have been emitted (or time out).
        t = 0;
        while (t < 4000000 && ncap < NOUT) begin @(posedge clk); t = t + 1; end

        mism = 0;
        for (idx = 0; idx < NOUT; idx = idx + 1)
            if (cap[idx] !== ref_out[idx]) begin
                if (mism < 6)
                    $display("  mismatch @%0d: got %02x expected %02x", idx, cap[idx], ref_out[idx]);
                mism = mism + 1;
            end

        $display("emitted %0d / %0d bytes, mismatches = %0d", ncap, NOUT, mism);
        if (ncap == NOUT && mism == 0)
            $display("RESULT: PASS - full 26x26 feature map matches the reference conv");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
