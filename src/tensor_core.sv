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
// Kinds (TCFG):  0 s8 : int8 x int8 -> int32 accumulate
//
// Timing per MMA: 8 shared-memory reads to stage A and B (pipelined, one
// per cycle once the port is granted), then 5 cycles per output column
// (4 rows x one 4-wide dot product each, plus the TMEM write) = ~30 cycles
// for 64 MACs, with 4 multipliers.
// ============================================================================
module tensor_core #(
    parameter TMEM_COLS = 16
) (
    input  wire        clk,
    input  wire        reset,

    // ---- issue (from thread 0 of the issuing warp, in UPDATE) ----
    input  wire        start,         // 1-cycle: begin an MMA
    input  wire [9:0]  a_addr,        // shared byte address of A (word aligned)
    input  wire [9:0]  b_addr,        // shared byte address of B (word aligned)
    input  wire [1:0]  d_tile,        // TMEM tile: columns d_tile*4 .. +3
    input  wire        accumulate,    // 1: D += A*B   0: D = A*B
    input  wire        cfg_we,        // TCFG: latch cfg_data
    input  wire [15:0] cfg_data,      //   [2:0] kind, [7:3] TLDQ shift
    output wire        busy,

    // ---- shared memory read port, borrowed from the thread LSUs ----
    output wire        sh_req,        // want the port (core holds off the LSUs)
    input  wire        sh_gnt,        // port is ours this cycle
    output reg  [7:0]  sh_raddr,      // word address
    input  wire [31:0] sh_rdata,      // valid the cycle after an address

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

    // ---------------- sequencer ----------------
    localparam S_IDLE = 2'd0, S_LOAD = 2'd1, S_DOT = 2'd2, S_WB = 2'd3;
    reg [1:0] state;
    assign busy   = (state != S_IDLE) || tm_we;   // last column still landing
    assign sh_req = (state == S_LOAD);

    reg [9:0] a_base, b_base;
    reg [1:0] tile;
    reg       acc;
    reg [3:0] ld_cnt;                 // next operand word to address (0..7)
    reg       ld_pend;                // an address went out last cycle
    reg [3:0] ld_item;                // ... for this operand word
    reg [1:0] col, row;
    reg signed [31:0] dot_r [0:3];    // this column's four dot products

    // operand word n: 0..3 = A rows, 4..7 = B columns
    always @(*) begin
        if (ld_cnt < 4) sh_raddr = a_base[9:2] + {6'd0, ld_cnt[1:0]};
        else            sh_raddr = b_base[9:2] + {6'd0, ld_cnt[1:0]};
    end

    // ---------------- datapath: one 4-wide dot product per cycle ----------------
    wire [31:0] arow = a_row[row];
    wire [31:0] bcol = b_col[col];
    reg  signed [31:0] dot;
    integer k;
    always @(*) begin
        dot = 32'sd0;
        for (k = 0; k < 4; k = k + 1)
            dot = dot + $signed(arow[8*k +: 8]) * $signed(bcol[8*k +: 8]);
    end

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
                        if (ld_item < 4) a_row[ld_item[1:0]] <= sh_rdata;
                        else             b_col[ld_item[1:0]] <= sh_rdata;
                    end
                    if (sh_gnt && ld_cnt < 4'd8) begin
                        ld_item <= ld_cnt;
                        ld_pend <= 1'b1;
                        ld_cnt  <= ld_cnt + 4'd1;
                    end else if (ld_cnt == 4'd8 && !ld_pend) begin
                        col    <= 2'd0;
                        row    <= 2'd0;
                        tm_col <= {tile, 2'd0};       // start reading old column 0
                        state  <= S_DOT;
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
                    if (col == 2'd3) begin
                        state <= S_IDLE;
                    end else begin
                        col    <= col + 2'd1;
                        tm_col <= {tile, col + 2'd1};
                        state  <= S_DOT;
                    end
                end
            endcase
        end
    end
endmodule
