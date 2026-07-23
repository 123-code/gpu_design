`timescale 1ns/1ps
module tb;
  logic clk = 0, rst, en;
  logic [7:0] count;
  int errors = 0;

  counter dut (.clk(clk), .rst(rst), .en(en), .count(count));
  always #5 clk = ~clk;

  initial begin
    rst = 1; en = 0;
    @(posedge clk); @(posedge clk); #1;
    if (count !== 8'd0) begin errors++; $display("FAIL: after reset count=%0d, expected 0", count); end

    rst = 0; en = 1;
    repeat (5) @(posedge clk); #1;
    if (count !== 8'd5) begin errors++; $display("FAIL: after 5 enabled cycles count=%0d, expected 5", count); end

    en = 0;
    repeat (3) @(posedge clk); #1;
    if (count !== 8'd5) begin errors++; $display("FAIL: count changed while en=0 (count=%0d, expected 5)", count); end

    en = 1;
    repeat (251) @(posedge clk); #1;  // 5 + 251 = 256 -> wraps to 0
    if (count !== 8'd0) begin errors++; $display("FAIL: no wrap, count=%0d, expected 0", count); end

    rst = 1;
    @(posedge clk); #1;
    if (count !== 8'd0) begin errors++; $display("FAIL: mid-run reset, count=%0d, expected 0", count); end

    if (errors == 0) $display("PASS: 01_counter");
    else             $display("01_counter: %0d check(s) FAILED", errors);
    $finish;
  end
endmodule
