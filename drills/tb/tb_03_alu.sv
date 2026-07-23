`timescale 1ns/1ps
module tb;
  logic [7:0] a, b, y;
  logic [1:0] op;
  logic zero;
  int errors = 0;

  mini_alu dut (.a(a), .b(b), .op(op), .y(y), .zero(zero));

  task check(input logic [7:0] ta, tb_, input logic [1:0] top);
    logic [7:0] exp;
    a = ta; b = tb_; op = top; #1;
    case (top)
      2'b00: exp = ta + tb_;
      2'b01: exp = ta - tb_;
      2'b10: exp = ta & tb_;
      2'b11: exp = ta | tb_;
    endcase
    if (y !== exp || zero !== (exp == 8'd0)) begin
      errors++;
      $display("FAIL: a=%0d b=%0d op=%b -> y=%0d zero=%b (expected y=%0d zero=%b)",
               ta, tb_, top, y, zero, exp, exp == 8'd0);
    end
  endtask

  initial begin
    check(8'd5,   8'd3,   2'b00);  // add
    check(8'd200, 8'd100, 2'b00);  // add with overflow wrap
    check(8'd7,   8'd7,   2'b01);  // sub to zero -> zero flag
    check(8'd3,   8'd5,   2'b01);  // sub underflow wrap
    check(8'hF0,  8'h0F,  2'b10);  // and -> 0 -> zero flag
    check(8'hF0,  8'h0F,  2'b11);  // or -> FF
    repeat (100) check($urandom, $urandom, $urandom);

    if (errors == 0) $display("PASS: 03_alu");
    else             $display("03_alu: %0d check(s) FAILED", errors);
    $finish;
  end
endmodule
