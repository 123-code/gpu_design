`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// HDMI (DVI) out, 640x480 @ 60 Hz: puts the raycaster's frame on a monitor.
//
// There is no framebuffer. The GPU's reply to the host is already one byte per
// screen column (half the wall's height, in pixels), so the scanout races the
// beam: every pixel reads its column's byte and paints wall, ceiling or floor.
//
//   capture (sys_clk)   snoops the bytes top.sv sends to the UART. A raycaster
//                       reply is [n][n columns][n][n columns]: core 0 renders the
//                       left half, core 1 the right. Any other reply is ignored.
//   three buffers       one being filled, the newest finished frame, and the one
//                       on screen. The screen adopts the newest frame only in
//                       vblank, so a frame is never shown half-updated.
//   scanout (pixel)     8 px per column, centred. 25.2 MHz pixel clock from a
//                       second rPLL (126 MHz) and CLKDIV /5; OSER10 serialises
//                       each TMDS channel into a TLVDS pair (pins in gpu.cst).
//
// Clocking, serialisers and IO follow apicula's Tang Nano 20K DVI example
// (examples/DVI). The hard macros exist only under `SYNTH: in simulation the
// pixel clock is the input clock and the TMDS pins idle low.
// ============================================================================
module hdmi_columns #(
    parameter COLS = 72                 // screen columns, 8 px each (<= 80)
) (
    input  wire       clk27,            // crystal: feeds the video PLL
    input  wire       sys_clk,
    input  wire       run_start,        // gpu_start: a new reply follows
    input  wire       byte_valid,       // top.sv's tx_start: one pulse per UART byte
    input  wire [7:0] byte_data,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);
    localparam N  = COLS / 2;           // columns per core
    localparam X0 = 320 - 4 * COLS;     // left edge of the picture

    // Buffer ids are one-hot so a 2-flop synchroniser can tell a stable value
    // from one caught mid-change (two bits flip at once).
    function onehot(input [2:0] b);
        onehot = (b == 3'b001) || (b == 3'b010) || (b == 3'b100);
    endfunction
    function [1:0] idx(input [2:0] b);
        idx = b[1] ? 2'd1 : b[2] ? 2'd2 : 2'd0;
    endfunction

    reg [7:0] colmem [0:511];           // {buffer, column} -> half wall height
    integer z;
    initial for (z = 0; z < 512; z = z + 1) colmem[z] = 8'd0;   // power-up: empty room

    // ---------------- capture (sys_clk) ----------------
    reg  [7:0] k = 8'd0;                // index of the next reply byte
    reg        ok = 1'b0;               // this reply still looks like a frame
    reg  [2:0] wbuf = 3'b001;           // buffer being filled
    reg  [2:0] done = 3'b010;           // newest finished frame
    reg  [2:0] front = 3'b100;          // on screen (pixel domain)
    reg  [2:0] front_s1 = 3'b100, front_s2 = 3'b100, front_seen = 3'b100;
    wire       len_byte = (k == 8'd0) || (k == N + 1);
    wire [7:0] wcol = (k <= N) ? k - 8'd1 : k - 8'd2;
    wire [2:0] free = ~(front_seen | wbuf);

    always @(posedge sys_clk) begin
        front_s1 <= front;
        front_s2 <= front_s1;
        if (onehot(front_s2)) front_seen <= front_s2;
        if (byte_valid && ok && !len_byte) colmem[{idx(wbuf), wcol[6:0]}] <= byte_data;
        if (run_start) begin
            k  <= 8'd0;
            ok <= 1'b1;
        end else if (byte_valid && ok) begin
            k <= k + 8'd1;
            if (len_byte && byte_data != N) ok <= 1'b0;     // another kernel's reply
            if (k == 2 * N + 1) begin                       // last column: publish
                ok   <= 1'b0;
                done <= wbuf;
                // ponytail: a frame finishing within ~3 sys cycles of a vblank swap
                // can still pick the buffer just put on screen (one torn frame);
                // a front->sys handshake removes it if that ever shows.
                wbuf <= free[0] ? 3'b001 : free[1] ? 3'b010 : 3'b100;
            end
        end
    end

    // ---------------- clocks ----------------
    wire clk_pixel, clk_x5, lock;
`ifdef SYNTH
    // 27 MHz * 14/3 = 126 MHz (VCO 504 MHz), apicula's examples/DVI/pll480.v
    rPLL #(
        .FCLKIN("27"),
        .DYN_IDIV_SEL("false"), .IDIV_SEL(2),
        .DYN_FBDIV_SEL("false"), .FBDIV_SEL(13),
        .DYN_ODIV_SEL("false"), .ODIV_SEL(4),
        .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW2A-18C")
    ) u_vpll (
        .CLKOUT(clk_x5), .LOCK(lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
    CLKDIV #(.DIV_MODE("5")) u_div (.HCLKIN(clk_x5), .RESETN(lock), .CLKOUT(clk_pixel));
`else
    assign clk_pixel = clk27;
    assign clk_x5    = clk27;
    assign lock      = 1'b1;
`endif

    // ---------------- timing (pixel clock): 800 x 525, syncs active low ----------------
    reg [9:0] cx = 10'd0, cy = 10'd0;
    reg [2:0] done_p1 = 3'b010, done_p2 = 3'b010;
    always @(posedge clk_pixel) begin
        cx <= (cx == 10'd799) ? 10'd0 : cx + 10'd1;
        if (cx == 10'd799) cy <= (cy == 10'd524) ? 10'd0 : cy + 10'd1;
        done_p1 <= done;
        done_p2 <= done_p1;
        if (cx == 10'd0 && cy == 10'd480 && onehot(done_p2)) front <= done_p2;  // vblank only
    end

    // stage A: read this pixel's column byte; register position and syncs alongside
    wire [9:0] vx = cx - X0;
    reg  [7:0] h = 8'd0;
    reg  [9:0] ay = 10'd0;
    reg        a_view = 1'b0, a_de = 1'b0, a_hs = 1'b1, a_vs = 1'b1;
    always @(posedge clk_pixel) begin
        h      <= colmem[{idx(front), vx[9:3]}];
        ay     <= cy;
        a_view <= cx >= X0 && cx < X0 + 8 * COLS && cy < 10'd480;
        a_de   <= cx < 10'd640 && cy < 10'd480;
        a_hs   <= !(cx >= 10'd656 && cx < 10'd752);
        a_vs   <= !(cy >= 10'd490 && cy < 10'd492);
    end

    // stage B: colour. A wall covers the rows within h of the horizon; nearer
    // walls are taller and brighter, and the floor brightens towards the viewer.
    wire       up   = ay < 10'd240;
    wire [8:0] dy = up ? 9'd240 - ay[8:0] : ay[8:0] - 9'd239;   // rows from the horizon, 1..240
    wire       wall = dy <= {1'b0, h};
    wire [8:0] wsum = 9'd48 + h;
    wire [7:0] wl   = wsum[8] ? 8'd255 : wsum[7:0];
    wire [7:0] fl   = 8'd24 + dy[8:1];
    reg [23:0] rgb = 24'd0;             // {r, g, b}
    reg        b_de = 1'b0, b_hs = 1'b1, b_vs = 1'b1;
    always @(posedge clk_pixel) begin
        rgb  <= !a_view ? 24'd0
              : wall    ? {wl, wl - (wl >> 2), wl >> 1}
              : up      ? {8'd16, 8'd20, 8'd40 + dy[8:2]}
              :           {fl, fl, fl};
        b_de <= a_de;
        b_hs <= a_hs;
        b_vs <= a_vs;
    end

    // ---------------- TMDS: blue carries the syncs ----------------
    wire [9:0] q [0:2];
    tmds_encoder e0 (.clk(clk_pixel), .d(rgb[7:0]),   .c({b_vs, b_hs}), .de(b_de), .q(q[0]));
    tmds_encoder e1 (.clk(clk_pixel), .d(rgb[15:8]),  .c(2'b00),        .de(b_de), .q(q[1]));
    tmds_encoder e2 (.clk(clk_pixel), .d(rgb[23:16]), .c(2'b00),        .de(b_de), .q(q[2]));

`ifdef SYNTH
    wire [2:0] ser;
    genvar i;
    generate
        for (i = 0; i < 3; i = i + 1) begin : g_ser
            OSER10 u_ser (
                .Q(ser[i]),
                .D0(q[i][0]), .D1(q[i][1]), .D2(q[i][2]), .D3(q[i][3]), .D4(q[i][4]),
                .D5(q[i][5]), .D6(q[i][6]), .D7(q[i][7]), .D8(q[i][8]), .D9(q[i][9]),
                .PCLK(clk_pixel), .FCLK(clk_x5), .RESET(!lock)
            );
            TLVDS_OBUF u_d (.I(ser[i]), .O(tmds_d_p[i]), .OB(tmds_d_n[i]));
        end
    endgenerate
    TLVDS_OBUF u_c (.I(clk_pixel), .O(tmds_clk_p), .OB(tmds_clk_n));
`else
    assign tmds_d_p   = 3'b000;
    assign tmds_d_n   = 3'b000;
    assign tmds_clk_p = 1'b0;
    assign tmds_clk_n = 1'b0;
`endif
endmodule

// ============================================================================
// TMDS 8b/10b for DVI: pixel data while de, else the four control symbols.
// The encoding is apicula's examples/DVI/tmds-channel.v (Sameer Puri's HDMI
// core, MIT), a direct implementation of HDMI 1.4a Figure 5-7; only the
// data-island modes are dropped. test/tb_hdmi.sv decodes every byte back.
// ============================================================================
module tmds_encoder (
    input  wire       clk,
    input  wire [7:0] d,
    input  wire [1:0] c,                // {c1, c0}: {vsync, hsync} on channel 0
    input  wire       de,
    output reg  [9:0] q = 10'b1101010100
);
    reg signed [4:0] acc = 5'sd0;       // running disparity
    reg        [8:0] q_m;
    reg        [9:0] q_out;
    reg        [3:0] n1d, n1m;
    reg signed [4:0] n1q, n0q, acc_add;
    integer i;

    always @(*) begin
        n1d = d[0] + d[1] + d[2] + d[3] + d[4] + d[5] + d[6] + d[7];
        q_m[0] = d[0];
        if (n1d > 4'd4 || (n1d == 4'd4 && d[0] == 1'b0)) begin
            for (i = 0; i < 7; i = i + 1) q_m[i + 1] = q_m[i] ~^ d[i + 1];
            q_m[8] = 1'b0;
        end else begin
            for (i = 0; i < 7; i = i + 1) q_m[i + 1] = q_m[i] ^ d[i + 1];
            q_m[8] = 1'b1;
        end
        n1m = q_m[0] + q_m[1] + q_m[2] + q_m[3] + q_m[4] + q_m[5] + q_m[6] + q_m[7];
        n1q = {1'b0, n1m};
        n0q = 5'sd8 - n1q;
        if (acc == 5'sd0 || n1q == n0q) begin
            if (q_m[8]) begin
                acc_add = n1q - n0q;
                q_out   = {~q_m[8], q_m[8], q_m[7:0]};
            end else begin
                acc_add = n0q - n1q;
                q_out   = {~q_m[8], q_m[8], ~q_m[7:0]};
            end
        end else if ((acc > 5'sd0 && n1q > n0q) || (acc < 5'sd0 && n1q < n0q)) begin
            q_out   = {1'b1, q_m[8], ~q_m[7:0]};
            acc_add = (n0q - n1q) + (q_m[8] ? 5'sd2 : 5'sd0);
        end else begin
            q_out   = {1'b0, q_m[8], q_m[7:0]};
            acc_add = (n1q - n0q) - (q_m[8] ? 5'sd0 : 5'sd2);
        end
    end

    always @(posedge clk) begin
        acc <= de ? acc + acc_add : 5'sd0;
        q   <= de ? q_out
             : c == 2'b00 ? 10'b1101010100
             : c == 2'b01 ? 10'b0010101011
             : c == 2'b10 ? 10'b0101010100
             :              10'b1010101011;
    end
endmodule
