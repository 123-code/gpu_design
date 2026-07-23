`timescale 1ns/1ps
module tb;
  logic clk = 0, rst, en, din;
  logic [7:0] q;
  int errors = 0;

  shift_reg dut (.clk(clk), .rst(rst), .en(en), .din(din), .q(q));
  always #5 clk = ~clk;

  task shift_in(input logic bitval);
    @(negedge clk) begin en = 1; din = bitval; end
    @(posedge clk); #1;
  endtask

  task check(input logic [7:0] exp, input string what);
    if (q !== exp) begin
      errors++;
      $display("FAIL: %s — q=%b, expected %b", what, q, exp);
    end
  endtask

  initial begin
    rst = 1; en = 0; din = 0;
    @(posedge clk); @(posedge clk); #1;
    check(8'b0, "after reset");
    rst = 0;

    shift_in(1); shift_in(0); shift_in(1); shift_in(1);
    check(8'b0000_1011, "after shifting in 1,0,1,1");

    @(negedge clk) en = 0; din = 1;
    repeat (2) @(posedge clk); #1;
    check(8'b0000_1011, "hold while en=0");

    shift_in(1); shift_in(1); shift_in(1); shift_in(1);
    check(8'b1011_1111, "after four more 1s");

    if (errors == 0) $display("PASS: 04_shift");
    else             $display("04_shift: %0d check(s) FAILED", errors);
    $finish;
  end
endmodule
