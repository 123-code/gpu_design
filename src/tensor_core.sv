`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Tensor core + Tensor Memory (TMEM), Blackwell style, at 4x4 scale.
//
// One MMA computes a 4x4 tile  D (+)= A x B  where
//   A : 4 x K, row-major in SHARED memory  (row i = one 32-bit word)
//   B : K x 4, stored K-major ("B transposed") in shared memory, so column j
//       of B is one 32-bit word -- the K-major smem layout tcgen05 reads
//   D : 4 x 4 int32 accumulators in TMEM, not in the register file
// with K = 4 for the 8-bit kinds. Like tcgen05.mma, the operands come
// straight from shared memory by address (the registers hold descriptors,
// not data), the result lands in a dedicated accumulator memory, and the
// instruction is ASYNCHRONOUS: the issuing warp keeps running while the unit
// works, and only an instruction that needs the unit (another MMA, TLD, TCFG)
// waits for it. Threads read results back with TLD: lane i gets row i of a
// TMEM column, the way tcgen05.ld gives each thread its own TMEM lane.
//
// TMEM is TMEM_COLS columns x 4 rows x 32 bits (16 columns = four 4x4 D
// tiles). Column c holds D[0..3][c%4] of tile c/4, one 128-bit word, so an
// MMA updates a whole column per write and a TLD hands every lane its row in
// one read. It is a single-read, single-write array (inferred as BSRAM).
//
// Kinds (TCFG kind field), the Blackwell low-precision formats:
//   0 s8    int8 x int8, K = 4.            D is a plain int32.
//   1 e4m3  FP8  (1-4-3), K = 4.           D is fixed point, 8 frac bits.
//   2 e2m1  FP4  (1-2-1), K = 8, two per byte (low nibble first). Q.8.
//   3 mxf4  e2m1 with OCP-MX block scales, K = 8. Each row of A and each
//           column of B carries one E8M0 scale (2^(s-127)); the 4 scale
//           bytes sit right after the tile (A+16, B+16). Block = one MMA's K.
//
// Float math is EXACT up to a single documented rounding: every product of
// two e4m3 (or e2m1) codes is an integer number of 2^-18 (or 2^-2) units,
// so each K-long dot product is summed exactly in a wide integer, and only
// then moved into D's Q.8 format -- a left shift (exact), or for e4m3 /
// small MX scales an arithmetic right shift (floor). software/tc_ref.py is
// the bit-exact model. No NaN/Inf: every code is a number (e2m1 has none;
// e4m3's NaN code reads as 480). FP4 multiplies are a few LUTs each, which
// is why Blackwell doubles K for them; here too, K = 8 vs 4.
//
// MMA2 (cta_group::2 in miniature): in a cluster launch the two cores' blocks
// form a pair, and MMA2 computes D(4x8) (+)= A(4xK) x B(Kx8) where B's
// columns 0..3 live in the rank-0 block's shared memory and columns 4..7 in
// the rank-1 block's, at the same address. Each core supplies its own A and
// gets its own 4 rows of the 8x8 result, in TMEM tiles t (cols 0..3) and
// t+1 (cols 4..7). The unit reads the peer's half of B (and its MX scales)
// over the cluster's distributed-shared-memory link, so each core only has
// to stage half of B: the point of pairing on Blackwell.
//
// Timing per MMA: 8 (10 for mxf4) shared-memory reads to stage A and B
// (pipelined, one per cycle once the port is granted), then 5 cycles per
// output column (4 rows x one K-wide dot product each, plus the TMEM write):
// ~30 cycles for 64 int8/fp8 MACs or 128 fp4 MACs.
// ============================================================================
module tensor_core #(
    parameter TMEM_COLS = 16,
    parameter KINDS     = 4'b1111      // kinds built (bit k = kind k); others compute 0
) (
    input  wire        clk,
    input  wire        reset,

    // ---- issue (from thread 0 of the issuing warp, in UPDATE) ----
    input  wire        start,         // 1-cycle: begin an MMA
    input  wire [9:0]  a_addr,        // shared byte address of A (word aligned)
    input  wire [9:0]  b_addr,        // shared byte address of B (word aligned)
    input  wire [1:0]  d_tile,        // TMEM tile: columns d_tile*4 .. +3
    input  wire        accumulate,    // 1: D += A*B   0: D = A*B
    input  wire        pair,          // MMA2: B split across the cluster pair
    input  wire        rank,          // this core's rank in the pair
    input  wire        cfg_we,        // TCFG: latch cfg_data
    input  wire [15:0] cfg_data,      //   [2:0] kind, [7:3] TLDQ shift
    output wire        busy,

    // ---- shared memory read port, borrowed from the thread LSUs ----
    output wire        sh_req,        // want the port (core holds off the LSUs)
    input  wire        sh_gnt,        // port is ours this cycle
    output reg  [7:0]  sh_raddr,      // word address
    input  wire [31:0] sh_rdata,      // valid the cycle after an address

    // ---- the peer core's shared memory (MMA2), req held until ack ----
    output reg         pr_req,
    output wire [7:0]  pr_addr,       // word address in the peer's shared memory
    input  wire        pr_ack,        // 1-cycle, with pr_data
    input  wire [31:0] pr_data,

    // ---- TLD: read one TMEM column (idle only) ----
    input  wire [3:0]  tld_col,
    output wire [127:0] tld_data,     // row r at [r*32 +: 32]
    output wire [4:0]  qshift         // TLDQ right shift (from TCFG)
);
    // ---------------- configuration (TCFG) ----------------
    reg [2:0] kind;
    reg [4:0] cfg_qshift;
    assign qshift = cfg_qshift;

    // ---------------- TMEM ----------------
    reg  [127:0] tmem [0:TMEM_COLS-1];
    reg  [127:0] tmem_rdata;
    reg  [3:0]   tm_col;              // column the MMA is reading
    reg  [3:0]   tm_waddr;            // column being written back
    reg          tm_we;
    reg  [127:0] tm_wdata;
    integer ti;
    initial for (ti = 0; ti < TMEM_COLS; ti = ti + 1) tmem[ti] = 128'd0; // sim: BSRAM powers up 0

    wire [3:0] tm_raddr = busy ? tm_col : tld_col;
    always @(posedge clk) begin
        if (tm_we) tmem[tm_waddr] <= tm_wdata;
        tmem_rdata <= tmem[tm_raddr];
    end
    assign tld_data = tmem_rdata;

    // ---------------- staged operands ----------------
    reg [31:0] a_row [0:3];           // A[i][k] = a_row[i][8k +: 8]
    reg [31:0] b_col [0:3];           // B[k][j] = b_col[j][8k +: 8]
    reg [31:0] a_scl, b_scl;          // mxf4: E8M0 scale of row i / column j
    reg [31:0] p_col [0:3];           // MMA2: the peer's 4 columns of B
    reg [31:0] p_scl;                 //       ... and their scales

    // ---------------- sequencer ----------------
    localparam S_IDLE = 3'd0, S_LOAD = 3'd1, S_DOT = 3'd2, S_WB = 3'd3, S_PEER = 3'd4;
    reg [2:0] state;
    assign busy   = (state != S_IDLE) || tm_we;   // last column still landing
    assign sh_req = (state == S_LOAD);
    // peer word n: 0..3 = its B columns, 4 = its B scales (mxf4)
    assign pr_addr = (pr_cnt == 3'd4) ? b_base[9:2] + 8'd4 : b_base[9:2] + {6'd0, pr_cnt[1:0]};
    wire [2:0] pr_items = (kind == 3'd3) ? 3'd5 : 3'd4;

    reg [9:0] a_base, b_base;
    reg [1:0] tile;
    reg       acc;
    reg [3:0] ld_cnt;                 // next operand word to address (0..9)
    reg       ld_pend;                // an address went out last cycle
    reg [3:0] ld_item;                // ... for this operand word
    reg [2:0] col;                    // 0..3, or 0..7 for MMA2
    reg [1:0] row;
    reg       pm;                     // this MMA is an MMA2
    reg       prk;                    // ... and this core's rank
    reg [2:0] pr_cnt;                 // peer words fetched (4, +1 scale word for mxf4)
    reg signed [31:0] dot_r [0:3];    // this column's four dot products

    // operand word n: 0..3 = A rows, 4..7 = B columns, 8/9 = A/B scales (mxf4)
    wire [3:0] n_items = (kind == 3'd3) ? 4'd10 : 4'd8;
    always @(*) begin
        if (ld_cnt < 4)       sh_raddr = a_base[9:2] + {6'd0, ld_cnt[1:0]};
        else if (ld_cnt < 8)  sh_raddr = b_base[9:2] + {6'd0, ld_cnt[1:0]};
        else if (ld_cnt == 8) sh_raddr = a_base[9:2] + 8'd4;
        else                  sh_raddr = b_base[9:2] + 8'd4;
    end

    // ---------------- datapath: one K-wide dot product per cycle ----------------
    // MMA2: B columns 0..3 come from rank 0's shared memory, 4..7 from
    // rank 1's. "Local" vs "peer" depends on which rank this core is.
    wire        col_hi   = col[2];
    wire        from_peer = pm && (col_hi != prk);
    wire [31:0] arow = a_row[row];
    wire [31:0] bcol = from_peer ? p_col[col[1:0]] : b_col[col[1:0]];
    wire [31:0] bscl = from_peer ? p_scl : b_scl;

    // s8: four signed 8x8 products
    reg signed [31:0] dot_s8;
    integer k;
    always @(*) begin
        dot_s8 = 32'sd0;
        for (k = 0; k < 4; k = k + 1)
            dot_s8 = dot_s8 + $signed(arow[8*k +: 8]) * $signed(bcol[8*k +: 8]);
    end

    // e4m3: value = M * 2^(E-9), M = {e!=0, mant}, E = max(e,1)-1.
    // Product of two = (Ma*Mb) << (Ea+Eb) units of 2^-18; four summed
    // exactly in 40 bits.
    function automatic [39:0] fp8_prod(input [7:0] a, input [7:0] b);
        reg [3:0] ma, mb, ea, eb;
        reg [7:0] m;
        reg [4:0] sh;                    // ea+eb reaches 28: needs 5 bits
        reg [39:0] mag;
        begin
            ma = {(a[6:3] != 4'd0), a[2:0]};
            mb = {(b[6:3] != 4'd0), b[2:0]};
            ea = (a[6:3] == 4'd0) ? 4'd0 : a[6:3] - 4'd1;
            eb = (b[6:3] == 4'd0) ? 4'd0 : b[6:3] - 4'd1;
            m   = ma * mb;
            sh  = {1'b0, ea} + {1'b0, eb};
            mag = {32'd0, m} << sh;
            fp8_prod = (a[7] ^ b[7]) ? -mag : mag;
        end
    endfunction
    reg signed [39:0] dot_fp8;
    always @(*) begin
        dot_fp8 = 40'sd0;
        for (k = 0; k < 4; k = k + 1)
            dot_fp8 = dot_fp8 + $signed(fp8_prod(arow[8*k +: 8], bcol[8*k +: 8]));
    end

    // e2m1: value = M * 2^(E-1), M = {e!=0, mant}, E = max(e,1)-1.
    // Product = (Ma*Mb) << (Ea+Eb) units of 2^-2 (at most 144); eight summed.
    function automatic [15:0] fp4_prod(input [3:0] a, input [3:0] b);
        reg [1:0] ma, mb, ea, eb;
        reg [3:0] m;                     // up to 9: a 2x2-bit product needs 4 bits
        reg [2:0] sh;                    // up to 4
        reg [15:0] mag;
        begin
            ma = {(a[2:1] != 2'd0), a[0]};
            mb = {(b[2:1] != 2'd0), b[0]};
            ea = (a[2:1] == 2'd0) ? 2'd0 : a[2:1] - 2'd1;
            eb = (b[2:1] == 2'd0) ? 2'd0 : b[2:1] - 2'd1;
            m   = ma * mb;
            sh  = {1'b0, ea} + {1'b0, eb};
            mag = {12'd0, m} << sh;
            fp4_prod = (a[3] ^ b[3]) ? -mag : mag;
        end
    endfunction
    reg signed [15:0] dot_fp4;
    always @(*) begin
        dot_fp4 = 16'sd0;
        for (k = 0; k < 8; k = k + 1)
            dot_fp4 = dot_fp4 + $signed(fp4_prod(arow[4*k +: 4], bcol[4*k +: 4]));
    end

    // mxf4 shift: the two E8M0 scales, plus 6 to go from 2^-2 units to Q.8,
    // clamped to [-24, 24]
    wire [7:0] sa = a_scl[8*row +: 8];
    wire [7:0] sb = bscl[8*col[1:0] +: 8];
    wire signed [10:0] mx_raw = $signed({3'b000, sa}) + $signed({3'b000, sb}) - 11'sd248;
    wire signed [10:0] mx_sh  = (mx_raw > 11'sd24) ? 11'sd24 : (mx_raw < -11'sd24) ? -11'sd24 : mx_raw;
    wire signed [39:0] fp4_wide = dot_fp4;
    wire signed [39:0] mx_val = (mx_sh >= 0) ? (fp4_wide <<< mx_sh[4:0]) : (fp4_wide >>> (-mx_sh));

    // What this (row, col) adds to D, mod 2^32
    reg signed [31:0] dot;
    always @(*) begin
        case (kind)
            3'd1:    dot = KINDS[1] ? (dot_fp8 >>> 10) : 32'sd0;            // 2^-18 -> Q.8, floor
            3'd2:    dot = KINDS[2] ? ({{16{dot_fp4[15]}}, dot_fp4} <<< 6) : 32'sd0;  // 2^-2 -> Q.8
            3'd3:    dot = KINDS[3] ? mx_val[31:0] : 32'sd0;
            default: dot = KINDS[0] ? dot_s8 : 32'sd0;
        endcase
    end

    wire [2:0] col_next = col + 3'd1;

    // D column update: old value (or 0) + this MMA's contribution, mod 2^32
    wire [127:0] old_col = tmem_rdata;
    wire [127:0] new_col;
    genvar gr;
    generate
        for (gr = 0; gr < 4; gr = gr + 1) begin : wb_rows
            assign new_col[gr*32 +: 32] = (acc ? old_col[gr*32 +: 32] : 32'd0) + dot_r[gr];
        end
    endgenerate

    always @(posedge clk) begin
        if (reset) begin
            state      <= S_IDLE;
            kind       <= 3'd0;
            cfg_qshift <= 5'd0;
            tm_we      <= 1'b0;
            tm_col     <= 4'd0;
            tm_waddr   <= 4'd0;
            ld_cnt     <= 4'd0;
            ld_pend    <= 1'b0;
            pr_req     <= 1'b0;
            pm         <= 1'b0;
        end else begin
            tm_we <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (cfg_we) begin
                        kind       <= cfg_data[2:0];
                        cfg_qshift <= cfg_data[7:3];
                    end
                    if (start) begin
                        a_base  <= a_addr;
                        b_base  <= b_addr;
                        tile    <= d_tile;
                        acc     <= accumulate;
                        pm      <= pair;
                        prk     <= rank;
                        ld_cnt  <= 4'd0;
                        ld_pend <= 1'b0;
                        state   <= S_LOAD;
                    end
                end

                // Stream the 8 operand words in: address n out while word
                // n-1 comes back.
                S_LOAD: begin
                    ld_pend <= 1'b0;
                    if (ld_pend) begin
                        if (ld_item < 4)       a_row[ld_item[1:0]] <= sh_rdata;
                        else if (ld_item < 8)  b_col[ld_item[1:0]] <= sh_rdata;
                        else if (ld_item == 8) a_scl <= sh_rdata;
                        else                   b_scl <= sh_rdata;
                    end
                    if (sh_gnt && ld_cnt < n_items) begin
                        ld_item <= ld_cnt;
                        ld_pend <= 1'b1;
                        ld_cnt  <= ld_cnt + 4'd1;
                    end else if (ld_cnt == n_items && !ld_pend) begin
                        col    <= 3'd0;
                        row    <= 2'd0;
                        tm_col <= {tile, 2'd0};       // start reading old column 0
                        if (pm) begin
                            pr_cnt <= 3'd0;
                            pr_req <= 1'b1;
                            state  <= S_PEER;
                        end else
                            state  <= S_DOT;
                    end
                end

                // MMA2: fetch the peer's half of B, one word per request
                S_PEER: begin
                    if (pr_ack) begin
                        if (pr_cnt == 3'd4) p_scl <= pr_data;
                        else                p_col[pr_cnt[1:0]] <= pr_data;
                        pr_cnt <= pr_cnt + 3'd1;
                        if (pr_cnt + 3'd1 == pr_items) begin
                            pr_req <= 1'b0;
                            state  <= S_DOT;
                        end
                    end
                end

                // Four rows of the current column, one per cycle. The old TMEM
                // column was addressed on entry and is valid from row 1 on.
                S_DOT: begin
                    dot_r[row] <= dot;
                    row <= row + 2'd1;
                    if (row == 2'd3) state <= S_WB;
                end

                S_WB: begin
                    tm_we    <= 1'b1;                 // tmem[tm_col] <= new_col
                    tm_waddr <= tm_col;
                    tm_wdata <= new_col;
                    if (col == (pm ? 3'd7 : 3'd3)) begin
                        state <= S_IDLE;
                    end else begin
                        col    <= col + 3'd1;
                        // columns 4..7 of an MMA2 land in the next tile
                        tm_col <= {tile + {1'b0, col_next[2]}, col_next[1:0]};
                        state  <= S_DOT;
                    end
                end
            endcase
        end
    end
endmodule
