`timescale 1ns/1ps
module tb;
  logic clk = 0, rst, wr_en, rd_en;
  logic [7:0] wdata, rdata;
  logic full, empty;
  int errors = 0;

  fifo dut (.clk(clk), .rst(rst), .wr_en(wr_en), .wdata(wdata),
            .rd_en(rd_en), .rdata(rdata), .full(full), .empty(empty));
  always #5 clk = ~clk;

  task tick;  // apply signals at negedge, let the posedge act, settle
    @(posedge clk); #1;
  endtask

  task expect_flags(input logic exp_full, exp_empty, input string what);
    if (full !== exp_full || empty !== exp_empty) begin
      errors++;
      $display("FAIL: %s — full=%b empty=%b (expected full=%b empty=%b)",
               what, full, empty, exp_full, exp_empty);
    end
  endtask

  task expect_head(input logic [7:0] exp, input string what);
    if (rdata !== exp) begin
      errors++;
      $display("FAIL: %s — rdata=%0d, expected %0d", what, rdata, exp);
    end
  endtask

  task push(input logic [7:0] d);
    @(negedge clk) begin wr_en = 1; rd_en = 0; wdata = d; end
    tick;
    @(negedge clk) wr_en = 0;
  endtask

  task pop;
    @(negedge clk) begin rd_en = 1; wr_en = 0; end
    tick;
    @(negedge clk) rd_en = 0;
  endtask

  initial begin
    rst = 1; wr_en = 0; rd_en = 0; wdata = 0;
    @(posedge clk); @(posedge clk); #1;
    rst = 0;
    expect_flags(0, 1, "after reset");

    push(8'd10);
    expect_flags(0, 0, "one element");
    expect_head(8'd10, "head after first push");

    push(8'd20); push(8'd30); push(8'd40);
    expect_flags(1, 0, "four elements = full");
    expect_head(8'd10, "head unchanged by pushes");

    push(8'd99);  // must be ignored: full
    expect_flags(1, 0, "write-when-full ignored (still full)");
    expect_head(8'd10, "write-when-full didn't corrupt head");

    pop; expect_head(8'd20, "pop -> next oldest (20)");
    pop; expect_head(8'd30, "pop -> 30");

    // simultaneous push+pop: pops 30, pushes 50; occupancy stays 2
    @(negedge clk) begin wr_en = 1; rd_en = 1; wdata = 8'd50; end
    tick;
    @(negedge clk) begin wr_en = 0; rd_en = 0; end
    expect_flags(0, 0, "push+pop same cycle keeps occupancy");
    expect_head(8'd40, "after push+pop, head is 40");

    pop; expect_head(8'd50, "then 50");
    pop;
    expect_flags(0, 1, "drained -> empty");

    pop;  // must be ignored: empty
    expect_flags(0, 1, "read-when-empty ignored");

    push(8'd77);
    expect_head(8'd77, "works after refill");
    expect_flags(0, 0, "one element after refill");

    if (errors == 0) $display("PASS: 06_fifo");
    else             $display("06_fifo: %0d check(s) FAILED", errors);
    $finish;
  end
endmodule
