`timescale 1ns/1ps
module tb;
  logic clk = 0, rst, sig;
  logic pulse;
  int errors = 0;

  edge_detect dut (.clk(clk), .rst(rst), .sig(sig), .pulse(pulse));
  always #5 clk = ~clk;

  // drive sig on negedges so edges sample it cleanly; check just after posedges
  task step(input logic s, input logic exp_pulse, input string what);
    @(negedge clk) sig = s;
    @(posedge clk); #1;
    if (pulse !== exp_pulse) begin
      errors++;
      $display("FAIL: %s — pulse=%b, expected %b", what, pulse, exp_pulse);
    end
  endtask

  initial begin
    rst = 1; sig = 0;
    @(posedge clk); @(posedge clk);
    rst = 0;

    step(0, 0, "sig low, no pulse");
    step(1, 1, "rise sampled -> one-cycle pulse");
    step(1, 0, "sig held high -> pulse must drop");
    step(1, 0, "still high, still no pulse");
    step(0, 0, "fall -> no pulse");
    step(1, 1, "second rise -> pulse again");
    step(0, 0, "done");

    if (errors == 0) $display("PASS: 02_edge");
    else             $display("02_edge: %0d check(s) FAILED", errors);
    $finish;
  end
endmodule
