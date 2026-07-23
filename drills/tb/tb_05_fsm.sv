`timescale 1ns/1ps
module tb;
  logic clk = 0, rst, din;
  logic seen;
  int errors = 0;

  seq_detect dut (.clk(clk), .rst(rst), .din(din), .seen(seen));
  always #5 clk = ~clk;

  // feed one bit, then check `seen` in the cycle after it was sampled
  task step(input logic bitval, input logic exp_seen, input string what);
    @(negedge clk) din = bitval;
    @(posedge clk); #1;
    if (seen !== exp_seen) begin
      errors++;
      $display("FAIL: %s — seen=%b, expected %b", what, seen, exp_seen);
    end
  endtask

  initial begin
    rst = 1; din = 0;
    @(posedge clk); @(posedge clk);
    rst = 0;

    // stream: 1 0 1 0 1 1 0 1  -> hits after bits 3, 5 (overlap), 8
    step(1, 0, "bit1=1");
    step(0, 0, "bit2=0");
    step(1, 1, "bit3=1 completes 101");
    step(0, 0, "bit4=0 (pulse must be one cycle)");
    step(1, 1, "bit5=1 completes overlapping 101");
    step(1, 0, "bit6=1 breaks pattern");
    step(0, 0, "bit7=0");
    step(1, 1, "bit8=1 completes 101 again");
    step(0, 0, "tail");
    step(0, 0, "second 0 clears progress");  // without this, ...1,0,1 would be a real hit

    // 1 1 0 0 1 -> never 101
    step(1, 0, "restart: 1");
    step(1, 0, "11");
    step(0, 0, "110");
    step(0, 0, "1100 (0 then 0 must reset progress)");
    step(1, 0, "11001 — no hit");

    if (errors == 0) $display("PASS: 05_fsm");
    else             $display("05_fsm: %0d check(s) FAILED", errors);
    $finish;
  end
endmodule
