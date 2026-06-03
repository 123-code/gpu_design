`timescale 1ns/1ns
// End-to-end check of the FC-MAC + argmax coprocessor against the Python
// reference (software/mnist_ref.py). Replays image 0's FC layer with the REAL
// trained weights/biases + the reference's 169 pooled features, then asserts the
// predicted digit == 7 (image 0's label, which the reference model also hits).
module tb_fc_mac;
    localparam D = "/Users/joseignacio/tiny-gpu-fpga/software/mnist_data";

    reg        clk = 0, reset = 1, frst = 0, mac_en = 0, farg = 0;
    reg  [7:0] px = 0, wt = 0;
    wire [7:0] result;

    fc_mac #(.BIAS_HEX({D, "/bias.hex"})) dut (
        .clk(clk), .reset(reset),
        .frst(frst), .mac_en(mac_en), .farg(farg),
        .px(px), .wt(wt), .result(result)
    );

    always #5 clk = ~clk;

    reg  [7:0] feats [0:168];     // 169 pooled features (from mnist_ref.py)
    reg  [7:0] allw  [0:1698];    // weights.hex: 0..8 conv, 9..1698 FC
    integer d, i, exp_digit;
    reg [1023:0] feat_path;

    task fmac(input [7:0] p, input [7:0] w);
        begin @(negedge clk); px = p; wt = w; mac_en = 1; @(negedge clk); mac_en = 0; end
    endtask

    initial begin
        // +FEAT=<path> selects the pooled-feature file; +EXP=<d> the reference digit.
        if (!$value$plusargs("FEAT=%s", feat_path)) feat_path = {D, "/features0.hex"};
        if (!$value$plusargs("EXP=%d", exp_digit))   exp_digit = 7;
        $readmemh(feat_path, feats);
        $readmemh({D, "/weights.hex"}, allw);

        @(negedge clk); reset = 0;
        @(negedge clk); frst = 1; @(negedge clk); frst = 0;   // start FC pass

        for (d = 0; d < 10; d = d + 1) begin
            for (i = 0; i < 169; i = i + 1)
                fmac(feats[i], allw[9 + d*169 + i]);          // acc += feat*weight
            @(negedge clk); farg = 1; @(negedge clk); farg = 0; // finalize digit d
        end

        @(posedge clk);
        if (result === exp_digit[7:0])
            $display("RESULT: PASS - predicted %0d == reference %0d", result, exp_digit);
        else
            $display("RESULT: FAIL - predicted %0d, reference %0d", result, exp_digit);
        $finish;
    end
endmodule
