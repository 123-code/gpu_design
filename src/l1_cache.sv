`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Per-core L1 data cache for global (SDRAM) memory.
//
// 256 bytes: 16 direct-mapped lines of 16 bytes (one SDRAM burst of 4 words).
// Global addresses are 16-bit byte addresses: tag [15:8], index [7:4],
// offset [3:0]. Threads reach it through LDG / STG, 16-bit halfwords.
//
//   LDG hit  : data back in 2 cycles
//   LDG miss : one 4-word burst from SDRAM fills the line, then the halfword
//   STG      : write-through, no write-allocate. The store is POSTED: the
//              thread is released as soon as the one-entry write buffer takes
//              it; the SDRAM write happens behind it. A hit also updates the
//              cached line. Loads wait for the buffer to drain first, so a
//              load always sees an earlier store.
//
// Like a GPU L1, it is not coherent with the other core's L1: a core sees
// its own stores, and a fresh block starts with an empty cache (the core's
// per-block reset invalidates it), so data handed between blocks or
// launches through global memory is always re-read from SDRAM.
// ============================================================================
module l1_cache (
    input  wire        clk,
    input  wire        reset,

    // loads (from the LSU read arbiter)
    input  wire        rd_req,
    input  wire [15:0] rd_addr,
    output reg         rd_ack,
    output reg  [15:0] rd_data,

    // stores (from the LSU write arbiter)
    input  wire        wr_req,
    input  wire [15:0] wr_addr,
    input  wire [15:0] wr_data,
    output wire        wr_ack,          // taken by the write buffer (same cycle)

    // global memory port
    output reg         m_req,
    output reg         m_we,
    output reg  [20:0] m_addr,
    output reg  [31:0] m_wdata,
    output reg  [3:0]  m_wbe,
    input  wire        m_ack,
    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,
    input  wire        m_done,

    output reg  [15:0] hits,
    output reg  [15:0] misses,
    // nothing in flight: no fill, no store still sitting in the write buffer
    output wire        idle
);
    reg [127:0] data  [0:15];
    reg [7:0]   tag   [0:15];
    reg [15:0]  valid;

    localparam S_IDLE = 3'd0, S_HIT = 3'd1, S_FILL = 3'd2, S_WRITE = 3'd3;
    reg [2:0]  state;

    // one-entry posted write buffer
    reg        wb_full;
    reg [15:0] wb_addr;
    reg [15:0] wb_data;
    // Not during a fill: a store to the line being filled would be lost
    // when the (older) SDRAM data lands on top of it.
    assign wr_ack = wr_req && !wb_full && (state != S_FILL);
    assign idle   = (state == S_IDLE) && !wb_full;

    reg [1:0]  beat;
    reg [15:0] cur;                     // address of the load being served

    wire [3:0] ri = rd_addr[7:4];
    wire       rd_hit = valid[ri] && tag[ri] == rd_addr[15:8];

    function [15:0] half_of(input [127:0] line, input [3:0] off);
        half_of = line[off[3:1]*16 +: 16];
    endfunction

    integer i;
    always @(posedge clk) begin
        if (reset) begin
            state  <= S_IDLE;
            valid  <= 16'd0;
            wb_full <= 1'b0;
            m_req  <= 1'b0;
            rd_ack <= 1'b0;
            hits   <= 16'd0;
            misses <= 16'd0;
        end else begin
            rd_ack <= 1'b0;

            // accept a store into the buffer; update the line on a hit
            if (wr_ack) begin
                wb_full <= 1'b1;
                wb_addr <= wr_addr;
                wb_data <= wr_data;
                if (valid[wr_addr[7:4]] && tag[wr_addr[7:4]] == wr_addr[15:8])
                    data[wr_addr[7:4]][wr_addr[3:1]*16 +: 16] <= wr_data;
            end

            case (state)
                S_IDLE: begin
                    if (wb_full) begin
                        // drain the store first (loads must see it)
                        m_req   <= 1'b1;
                        m_we    <= 1'b1;
                        m_addr  <= {7'd0, wb_addr[15:2]};
                        m_wdata <= {wb_data, wb_data};
                        m_wbe   <= wb_addr[1] ? 4'b1100 : 4'b0011;
                        state   <= S_WRITE;
                    end else if (rd_req && !rd_ack && !wr_ack) begin  // a store just taken drains first
                        cur <= rd_addr;
                        if (rd_hit) begin
                            hits  <= hits + 16'd1;
                            state <= S_HIT;
                        end else begin
                            misses <= misses + 16'd1;
                            m_req  <= 1'b1;
                            m_we   <= 1'b0;
                            m_addr <= {7'd0, rd_addr[15:4], 2'b00};
                            beat   <= 2'd0;
                            state  <= S_FILL;
                        end
                    end
                end
                S_HIT: begin
                    rd_ack  <= 1'b1;
                    rd_data <= half_of(data[cur[7:4]], cur[3:0]);
                    state   <= S_IDLE;
                end
                S_FILL: begin
                    if (m_ack) m_req <= 1'b0;
                    if (m_rvalid) begin
                        data[cur[7:4]][beat*32 +: 32] <= m_rdata;
                        beat <= beat + 2'd1;
                    end
                    if (m_done) begin
                        tag[cur[7:4]]   <= cur[15:8];
                        valid[cur[7:4]] <= 1'b1;
                        state <= S_HIT;          // serve it from the new line
                    end
                end
                S_WRITE: begin
                    if (m_ack) m_req <= 1'b0;
                    if (m_done) begin
                        wb_full <= 1'b0;
                        state   <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
