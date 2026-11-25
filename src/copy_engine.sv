`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Bulk copy engine (the TMA's job, at this scale).
//
// `TMA Rs, Rt, #n` hands the engine one copy: n 32-bit words (n = 1..8, i.e.
// 4..32 bytes, a whole operand tile) from data memory at byte address Rs to
// shared memory at byte address Rt (word aligned). The instruction does not
// wait for the data. The warp keeps issuing -- typically an MMA on the tile
// that already arrived -- while the engine streams the next one in, one byte
// per cycle. `TMAWAIT` parks the warp until every copy the core issued has
// landed (cp.async.bulk + wait_group 0, or an mbarrier wait, in CUDA terms).
//
// The engine borrows two ports: the core's data-memory read port (the LSU
// read arbiter holds off new requests and the engine takes the port once no
// LSU read is in flight) and the shared-memory write port (the LSU write
// arbiter grants nothing while the engine asks; the engine writes from the
// cycle after it asked, so the arbiter's last registered write has landed).
//
// One copy in flight; a TMA issued while one is running waits for it (the
// scheduler parks and retries, like a tensor-core op on a busy unit).
// ============================================================================
module copy_engine #(
    parameter ADDR_BITS = 13
) (
    input  wire                 clk,
    input  wire                 reset,

    input  wire                 start,       // 1-cycle (UPDATE of a TMA)
    input  wire [ADDR_BITS-1:0] src,         // data-memory byte address
    input  wire [9:0]           dst,         // shared byte address (word aligned)
    input  wire [3:0]           nwords,      // 1..8
    output wire                 busy,

    // data-memory read port (borrowed)
    output wire                 rd_req,
    input  wire                 rd_gnt,
    output wire [ADDR_BITS-1:0] rd_addr,
    input  wire [7:0]           rd_data,     // valid the cycle after rd_addr

    // shared-memory write port (borrowed)
    output wire                 wr_req,
    output reg                  sh_we,
    output reg  [7:0]           sh_waddr,
    output reg  [31:0]          sh_wdata,
    output reg  [3:0]           sh_wbe
);
    reg                 active;
    reg [ADDR_BITS-1:0] s_ptr;
    reg [9:0]           d_ptr;               // byte address the next byte lands at
    reg [5:0]           left;                // bytes still to address
    reg [5:0]           inflight_left;       // bytes still to write
    reg                 pend;                // a read went out last cycle
    reg [1:0]           pend_lane;
    reg [7:0]           pend_word;
    reg                 wr_ok;               // write port drained (asked >= 1 cycle ago)

    assign busy    = active;
    assign rd_req  = active && (left != 6'd0);
    assign wr_req  = active;
    assign rd_addr = s_ptr;

    always @(posedge clk) begin
        if (reset) begin
            active <= 1'b0;
            pend   <= 1'b0;
            sh_we  <= 1'b0;
            wr_ok  <= 1'b0;
            left   <= 6'd0;
            inflight_left <= 6'd0;
        end else begin
            sh_we <= 1'b0;
            wr_ok <= active;
            if (!active) begin
                if (start) begin
                    active        <= 1'b1;
                    s_ptr         <= src;
                    d_ptr         <= {dst[9:2], 2'b00};
                    left          <= {nwords, 2'b00};
                    inflight_left <= {nwords, 2'b00};
                    pend          <= 1'b0;
                end
            end else begin
                // address the next byte
                pend <= 1'b0;
                if (rd_gnt && left != 6'd0) begin
                    pend      <= 1'b1;
                    pend_lane <= d_ptr[1:0];
                    pend_word <= d_ptr[9:2];
                    s_ptr     <= s_ptr + 1'b1;
                    d_ptr     <= d_ptr + 10'd1;
                    left      <= left - 6'd1;
                end
                // land the byte that came back (the read went out last cycle;
                // by then the write port has drained)
                if (pend) begin
                    sh_we    <= 1'b1;
                    sh_waddr <= pend_word;
                    sh_wdata <= {4{rd_data}};
                    sh_wbe   <= 4'b0001 << pend_lane;
                    inflight_left <= inflight_left - 6'd1;
                    if (inflight_left == 6'd1) active <= 1'b0;
                end
            end
        end
    end

    // wr_ok is informational: a read is granted no earlier than the cycle
    // after rd_req rose, so the first write (two cycles after that) always
    // follows a full cycle of the write arbiter being held.
    wire _unused = wr_ok;
endmodule
