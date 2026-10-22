`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// The HDMI path (src/hdmi.sv) checked without a monitor:
//   * TMDS: 512 scrambled bytes plus long runs of 0xFF / 0x01 decode back to
//     themselves, the running disparity stays bounded, and blanking sends the
//     four DVI control symbols
//   * capture + scanout: a raycaster-shaped reply lands in a buffer, the screen
//     adopts it in vblank, and sampled pixels have hand-computed colours; a
//     reply that isn't a raycaster frame is ignored; a second frame replaces it
//   * timing: 800-px lines, 525-line frames, 96-px hsync, 2-line vsync
// ============================================================================
module tb;
    reg clk = 0;
    always #5 clk = ~clk;

    integer bad = 0;
    task expect_eq(input [255:0] what, input integer got, input integer want);
        if (got !== want) begin
            $display("  FAIL %0s: got %h, expected %h", what, got, want);
            bad = bad + 1;
        end
    endtask

    // ---------------- TMDS round trip ----------------
    reg  [7:0] d = 0;
    reg  [1:0] c = 0;
    reg        de = 0;
    wire [9:0] q;
    tmds_encoder enc (.clk(clk), .d(d), .c(c), .de(de), .q(q));

    function [7:0] decode(input [9:0] s);
        reg [7:0] t;
        integer j;
        begin
            t = s[9] ? ~s[7:0] : s[7:0];
            decode[0] = t[0];
            for (j = 1; j < 8; j = j + 1)
                decode[j] = s[8] ? t[j] ^ t[j - 1] : ~(t[j] ^ t[j - 1]);
        end
    endfunction

    integer i, disp = 0, worst = 0, wrong = 0;
    task symbol(input [7:0] b);       // send one pixel byte, check what comes out
        integer j;
        begin
            d = b;
            @(posedge clk); #1;
            if (decode(q) !== b) wrong = wrong + 1;
            for (j = 0; j < 10; j = j + 1) disp = disp + (q[j] ? 1 : -1);
            if (disp > worst) worst = disp;
            if (-disp > worst) worst = -disp;
        end
    endtask

    // ---------------- capture + scanout ----------------
    reg        run_start = 0, byte_valid = 0;
    reg  [7:0] byte_data = 0;
    wire       tcp, tcn;
    wire [2:0] tdp, tdn;
    hdmi_columns #(.COLS(72)) v (
        .clk27(clk), .sys_clk(clk), .run_start(run_start),
        .byte_valid(byte_valid), .byte_data(byte_data),
        .tmds_clk_p(tcp), .tmds_clk_n(tcn), .tmds_d_p(tdp), .tmds_d_n(tdn)
    );

    task send(input [7:0] b);
        begin
            @(negedge clk); byte_valid = 1; byte_data = b;
            @(negedge clk); byte_valid = 0;
        end
    endtask

    // A reply shaped like raycast.jpp's: [len][36 columns][len][36 columns].
    // flat = 0: column 0 is a full-height wall, 1 empty, 2 half height 100, the
    // rest c. flat = 1: every column empty.
    task reply(input [7:0] len, input flat);
        integer col;
        begin
            @(negedge clk); run_start = 1;
            @(negedge clk); run_start = 0;
            for (col = 0; col < 72; col = col + 1) begin
                if (col == 0 || col == 36) send(len);
                send(flat ? 8'd0 : col == 0 ? 8'd240 : col == 1 ? 8'd0 : col == 2 ? 8'd100 : col);
            end
        end
    endtask

    // Colour of pixel (x, y) on the next pass of the beam: rgb lags the
    // counters by two clocks (stage A reads the column, stage B colours it).
    task pixel(input integer x, input integer y, input integer want);
        begin
            wait (v.cx == x + 2 && v.cy == y);
            #1 expect_eq("pixel colour", v.rgb, want);
        end
    endtask

    task next_frame;    // past the next vblank, where the screen adopts a new frame
        begin
            wait (v.cy == 480 && v.cx == 1);
            wait (v.cy == 0);
        end
    endtask

    // ---------------- sync timing ----------------
    time hs_fall = 0, hs_period = 0, hs_low = 0, vs_fall = 0, vs_period = 0, vs_low = 0;
    always @(negedge v.b_hs) begin if (hs_fall != 0) hs_period = $time - hs_fall; hs_fall = $time; end
    always @(posedge v.b_hs) if (hs_fall != 0) hs_low = $time - hs_fall;
    always @(negedge v.b_vs) begin if (vs_fall != 0) vs_period = $time - vs_fall; vs_fall = $time; end
    always @(posedge v.b_vs) if (vs_fall != 0) vs_low = $time - vs_fall;

    reg [2:0] done_before;
    initial begin
        // ---- TMDS ----
        @(negedge clk); de = 1;
        for (i = 0; i < 512; i = i + 1) symbol((i * 37 + 11) % 256);   // every byte, twice
        for (i = 0; i < 64; i = i + 1) symbol(8'hFF);                   // all ones: must invert
        for (i = 0; i < 64; i = i + 1) symbol(8'h01);
        expect_eq("TMDS bytes that decode wrong", wrong, 0);
        if (worst > 16) begin
            $display("  FAIL running disparity reached %0d", worst);
            bad = bad + 1;
        end
        de = 0;
        c = 2'b00; @(posedge clk); #1 expect_eq("control 00", q, 10'b1101010100);
        c = 2'b01; @(posedge clk); #1 expect_eq("control 01", q, 10'b0010101011);
        c = 2'b10; @(posedge clk); #1 expect_eq("control 10", q, 10'b0101010100);
        c = 2'b11; @(posedge clk); #1 expect_eq("control 11", q, 10'b1010101011);
        $display("  TMDS: 640 bytes round-tripped, worst disparity %0d", worst);

        // ---- a frame on screen ----
        reply(8'd36, 1'b0);
        next_frame;
        pixel(35,  10, 24'hFFC07F);     // column 0, half height 240: wall, full brightness
        pixel(43, 100, 24'h10144B);     // column 1, empty: ceiling
        pixel(43, 400, 24'h686868);     // column 1: floor
        pixel(51, 139, 24'h101441);     // column 2, half height 100: one row above the wall
        pixel(51, 140, 24'h946F4A);     // column 2: the wall's top row
        pixel(604, 240, 24'h775A3B);    // column 71, half height 71: wall at the horizon
        pixel(5,   200, 24'h000000);    // left border
        pixel(610, 240, 24'h000000);    // right border

        // ---- another kernel's reply is ignored ----
        done_before = v.done;
        reply(8'd7, 1'b1);
        next_frame;
        expect_eq("buffer after a non-raycaster reply", v.done, done_before);
        pixel(35, 10, 24'hFFC07F);      // still the first frame

        // ---- a second frame replaces it ----
        reply(8'd36, 1'b1);
        next_frame;
        pixel(35, 10, 24'h101461);      // column 0 is empty now: ceiling

        expect_eq("hsync period (clocks)", hs_period / 10, 800);
        expect_eq("hsync width (clocks)", hs_low / 10, 96);
        expect_eq("vsync period (clocks)", vs_period / 10, 800 * 525);
        expect_eq("vsync width (clocks)", vs_low / 10, 2 * 800);

        if (bad == 0) $display("RESULT: PASS - HDMI encoding, capture, scanout and timing");
        else          $display("RESULT: FAIL - %0d checks", bad);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("RESULT: FAIL - global timeout");
        $finish;
    end
endmodule
