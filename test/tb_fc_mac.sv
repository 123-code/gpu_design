`timescale 1ns/1ns
// Directed test for the FC-MAC coprocessor: FCLR -> FMAC* -> FRD readout.
module tb_fc_mac;
    reg        clk = 0, reset = 1, clear = 0, mac_en = 0;
    reg  [7:0] px = 0, wt = 0;
    wire [7:0] result;

    fc_mac #(.Q(6)) dut (
        .clk(clk), .reset(reset),
        .clear(clear), .mac_en(mac_en),
        .px(px), .wt(wt), .result(result)
    );

    always #5 clk = ~clk;

    // Drive one FMAC: present operands, pulse mac_en for a single posedge.
    task fmac(input [7:0] p, input signed [7:0] w);
        begin
            @(negedge clk); px = p; wt = w; mac_en = 1;
            @(negedge clk); mac_en = 0;
        end
    endtask

    integer errors = 0;
    task check(input signed [7:0] got, input signed [7:0] exp, input [127:0] name);
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got %0d, expected %0d", name, got, exp);
                errors = errors + 1;
            end else
                $display("ok   %0s = %0d", name, got);
        end
    endtask

    initial begin
        @(negedge clk); reset = 0;

        // Test 1: 10*2 + 20*(-1) + 30*3 = 90 ; 90 >> 6 = 1
        @(negedge clk); clear = 1; @(negedge clk); clear = 0;
        fmac(8'd10,  8'sd2);
        fmac(8'd20, -8'sd1);
        fmac(8'd30,  8'sd3);
        check($signed(result), 8'sd1, "dotprod 90>>6");

        // Test 2: clear resets the accumulator
        @(negedge clk); clear = 1; @(negedge clk); clear = 0;
        check($signed(result), 8'sd0, "after FCLR");

        // Test 3: positive saturation. 255*127 = 32385 ; >>6 = 506 -> clamp 127
        fmac(8'd255, 8'sd127);
        check($signed(result), 8'sd127, "pos saturate");

        // Test 4: negative saturation. add 255*(-128) -> large negative -> clamp -128
        fmac(8'd255, -8'sd128);
        fmac(8'd255, -8'sd128);
        check($signed(result), -8'sd128, "neg saturate");

        if (errors == 0) $display("RESULT: PASS - FC-MAC coprocessor correct");
        else             $display("RESULT: FAIL - %0d error(s)", errors);
        $finish;
    end
endmodule
