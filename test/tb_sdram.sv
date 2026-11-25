`default_nettype none
`timescale 1ns/1ns

// SDRAM controller vs the checking SDRAM model, standalone.
//
// Writes 300 random words (random byte enables) at random addresses, keeps a
// shadow copy, and reads every touched line back (burst 4), comparing all
// four beats. Long enough that several refreshes interleave with traffic.
// Passes only if the data matches AND the model saw no protocol violation.
module tb;
    reg clk = 0;
    reg reset = 1;
    always #5 clk = ~clk;

    reg         req = 0, we = 0;
    reg  [20:0] addr = 0;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wbe = 0;
    wire        ack, rvalid, done, init_done;
    wire [31:0] rdata;

    wire cke, cs_n, ras_n, cas_n, we_n;
    wire [1:0] ba; wire [10:0] a; wire [3:0] dqm; wire [31:0] dq;

    sdram_ctrl #(.INIT_CYCLES(100), .REF_INTERVAL(200)) ctrl (
        .clk(clk), .reset(reset),
        .req(req), .we(we), .addr(addr), .wdata(wdata), .wbe(wbe),
        .ack(ack), .rvalid(rvalid), .rdata(rdata), .done(done), .init_done(init_done),
        .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n),
        .sdram_we_n(we_n), .sdram_ba(ba), .sdram_addr(a), .sdram_dqm(dqm), .sdram_dq(dq)
    );
    sdram_model #(.T_REFI_MAX(400)) chip (
        .clk(~clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .ba(ba), .addr(a), .dqm(dqm), .dq(dq)
    );

    // shadow of the words written (addresses confined to 1024 words)
    reg [31:0] shadow [0:1023];
    reg        touched [0:1023];
    integer i, j, fails, seed, beat;
    reg [31:0] lo;

    task automatic op_write(input [20:0] ad, input [31:0] d, input [3:0] be);
        begin
            @(posedge clk); req <= 1; we <= 1; addr <= ad; wdata <= d; wbe <= be;
            @(posedge clk); while (!ack) @(posedge clk);
            req <= 0;
            while (!done) @(posedge clk);
        end
    endtask

    reg [31:0] line [0:3];
    task automatic op_read(input [20:0] ad);
        begin
            @(posedge clk); req <= 1; we <= 0; addr <= ad;
            @(posedge clk); while (!ack) @(posedge clk);
            req <= 0;
            beat = 0;
            while (!done) begin
                @(posedge clk);
                if (rvalid) begin line[beat] = rdata; beat = beat + 1; end
            end
        end
    endtask

    // Map the 1024-word test window across rows and banks:
    // word w -> {row = w[9:6], bank = w[5:4]... } via a scramble
    function automatic [20:0] phys(input integer w);
        phys = {7'd0, w[9:6], w[5:4], 2'b00, w[3:0]} ^ 21'h0;
    endfunction

    initial begin
        fails = 0; seed = 7;
        for (i = 0; i < 1024; i = i + 1) begin shadow[i] = 0; touched[i] = 0; end
        repeat (5) @(posedge clk); reset = 0;
        while (!init_done) @(posedge clk);

        for (i = 0; i < 300; i = i + 1) begin
            j = $unsigned($random(seed)) % 1024;
            lo = $random(seed);
            wbe = $random(seed);
            if (wbe == 0) wbe = 4'b1111;
            op_write(phys(j), lo, wbe);
            if (wbe[0]) shadow[j][7:0]   = lo[7:0];
            if (wbe[1]) shadow[j][15:8]  = lo[15:8];
            if (wbe[2]) shadow[j][23:16] = lo[23:16];
            if (wbe[3]) shadow[j][31:24] = lo[31:24];
            touched[j] = 1;
        end
        for (i = 0; i < 1024; i = i + 4) begin
            if (touched[i] || touched[i+1] || touched[i+2] || touched[i+3]) begin
                op_read(phys(i));
                if (beat != 4) begin fails = fails + 1; $display("  line %0d: %0d beats", i, beat); end
                for (j = 0; j < 4; j = j + 1)
                    if (line[j] !== shadow[i + j]) begin
                        if (fails < 10) $display("  word %0d: got %08x want %08x", i + j, line[j], shadow[i + j]);
                        fails = fails + 1;
                    end
            end
        end

        $display("model: %0d activates, %0d reads, %0d writes, %0d refreshes, %0d violations",
                 chip.activates, chip.reads, chip.writes, chip.refreshes, chip.violations);
        if (fails == 0 && chip.violations == 0 && chip.refreshes > 4)
            $display("RESULT: PASS - SDRAM controller: 300 masked writes, every line read back, protocol clean");
        else
            $display("RESULT: FAIL - %0d data mismatches, %0d protocol violations", fails, chip.violations);
        $finish;
    end

    initial begin
        #5000000;
        $display("RESULT: FAIL - timeout");
        $finish;
    end
endmodule
