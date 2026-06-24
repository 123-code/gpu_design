`default_nettype none
`timescale 1ns/1ns

// Serializes many thread LSUs' WRITE requests onto main_memory's single write
// port. Mirror of lsu_arbiter.sv (which does the same for reads), but simpler:
// a BRAM write commits in one cycle, so there is no read-latency WAIT state.
//
// Each cycle: if any write is pending, pick the lowest-index requester, drive
// the memory write port with its address/data, and pulse that lane's wgrant the
// SAME cycle. The lane's LSU holds we_req until it sees wgrant, then advances.
// N lanes writing at once drain over N cycles (one commit per cycle).
//
// Without this, only thread 0 could write (core.sv hardwired the port to lane 0),
// so a SIMT layer could not emit one result per lane. This is the unlock that
// lets each lane scatter its own output to a distinct address.
module lsu_write_arbiter #(
    parameter THREADS   = 4,
    parameter ADDR_BITS = 13
) (
    input  wire                 clk,
    input  wire                 reset,

    // ---- write requests from the thread LSUs ----
    input  wire [THREADS-1:0]      we_req,                // held until granted
    input  wire [ADDR_BITS-1:0]    waddr [THREADS-1:0],
    input  wire [7:0]              wdata [THREADS-1:0],

    // ---- single write port into main_memory ----
    output reg                  mem_we,
    output reg  [ADDR_BITS-1:0] mem_waddr,
    output reg  [7:0]           mem_wdata,

    // ---- per-lane grant (1-cycle pulse, same cycle the write commits) ----
    output reg  [THREADS-1:0]   wgrant
);
    localparam IDX = (THREADS <= 1) ? 1 : $clog2(THREADS);

    // A just-granted lane keeps asserting we_req for one more cycle (it clears on
    // the registered wgrant), so mask it out for that cycle to avoid a double
    // grant. last_grant_oh holds the one-hot of the lane granted last cycle.
    reg [THREADS-1:0] last_grant_oh;
    wire [THREADS-1:0] pending = we_req & ~last_grant_oh;

    // Lowest set request bit (iterate high->low so the lowest index wins),
    // matching lsu_arbiter.sv's picker.
    integer k;
    reg           any;
    reg [IDX-1:0] sel;
    always @(*) begin
        any = 1'b0; sel = '0;
        for (k = THREADS-1; k >= 0; k = k - 1)
            if (pending[k]) begin sel = k[IDX-1:0]; any = 1'b1; end
    end

    always @(posedge clk) begin
        if (reset) begin
            mem_we        <= 1'b0;
            mem_waddr     <= '0;
            mem_wdata     <= 8'd0;
            wgrant        <= '0;
            last_grant_oh <= '0;
        end else begin
            wgrant        <= '0;           // wgrant is a 1-cycle pulse
            last_grant_oh <= '0;
            if (any) begin
                mem_we      <= 1'b1;       // commit this lane's write this cycle
                mem_waddr   <= waddr[sel];
                mem_wdata   <= wdata[sel];
                wgrant[sel] <= 1'b1;       // ack the granted lane
                last_grant_oh[sel] <= 1'b1;
            end else begin
                mem_we <= 1'b0;
            end
        end
    end
endmodule
