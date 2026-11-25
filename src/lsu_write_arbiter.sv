`default_nettype none
`timescale 1ns/1ns

// Serializes many thread LSUs' WRITE requests onto the core's memory write
// ports. Mirror of lsu_arbiter.sv (which does the same for reads), but simpler:
// a BRAM write commits in one cycle, so there is no read-latency WAIT state.
//
// Each cycle: if any write is pending, pick the lowest-index requester, drive
// the memory write port with its address/data, and pulse that lane's wgrant the
// SAME cycle. The lane's LSU holds we_req until it sees wgrant, then advances.
// N lanes writing at once drain over N cycles (one commit per cycle).
//
// Two address spaces, as in lsu_arbiter.sv:
//   space 0  main memory: the low byte of wdata at waddr
//   space 1  shared memory: the 16-bit halfword at byte address waddr, as a
//            32-bit word write with byte enables (addr[1] picks the half)
// `hold` grants nothing (another unit, the copy engine, owns the shared
// write port this cycle).
module lsu_write_arbiter #(
    parameter THREADS   = 4,
    parameter ADDR_BITS = 13
) (
    input  wire                 clk,
    input  wire                 reset,

    // ---- write requests from the thread LSUs ----
    input  wire [THREADS-1:0]      we_req,                // held until granted
    input  wire [ADDR_BITS-1:0]    waddr [THREADS-1:0],
    input  wire [15:0]             wdata [THREADS-1:0],
    input  wire [1:0]              space [THREADS-1:0],   // 0 main, 1 shared, 2 global

    input  wire                    hold,

    // ---- main memory write port ----
    // ---- global memory (the core's L1 write buffer; takes it or not, same cycle) ----
    output wire                 g_wreq,
    output wire [15:0]          g_waddr,
    output wire [15:0]          g_wdata,
    input  wire                 g_wack,

    // ---- DSMEM: this core's store into the PEER's shared memory (STS with
    //      address bit 10), taken or not the same cycle ----
    output wire                 r_wreq,
    output wire [9:0]           r_waddr,
    output wire [15:0]          r_wdata,
    input  wire                 r_wack,
    // ---- ... and the peer's stores into OURS. Served first, ahead of our
    //      own lanes, so two cores storing into each other cannot deadlock ----
    input  wire                 x_wreq,
    input  wire [9:0]           x_waddr,
    input  wire [15:0]          x_wdata,
    output wire                 x_wack,

    output reg                  mem_we,
    output reg  [12:0]          mem_waddr,
    output reg  [7:0]           mem_wdata,

    // ---- shared memory write port ----
    output reg                  sh_we,
    output reg  [7:0]           sh_waddr,               // word address
    output reg  [31:0]          sh_wdata,
    output reg  [3:0]           sh_wbe,

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

    // A global store goes to the L1 combinationally and is granted when the
    // write buffer takes it (g_wack); until then the lane keeps waiting.
    assign g_wreq  = any && !hold && (space[sel] == 2'd2);

    wire to_peer = (space[sel] == 2'd1) && waddr[sel][10];
    assign r_wreq  = any && !hold && to_peer;
    assign r_waddr = waddr[sel][9:0];
    assign r_wdata = wdata[sel];
    assign x_wack  = x_wreq && !hold;
    // Can the selected lane be granted this cycle?
    wire sel_ok = (space[sel] == 2'd2) ? g_wack
                : to_peer              ? r_wack
                : (space[sel] == 2'd1) ? !x_wack     // our shared port is taken by the peer
                :                        1'b1;
    assign g_waddr = waddr[sel][15:0];
    assign g_wdata = wdata[sel];

    always @(posedge clk) begin
        if (reset) begin
            mem_we        <= 1'b0;
            mem_waddr     <= '0;
            mem_wdata     <= 8'd0;
            sh_we         <= 1'b0;
            sh_waddr      <= 8'd0;
            sh_wdata      <= 32'd0;
            sh_wbe        <= 4'd0;
            wgrant        <= '0;
            last_grant_oh <= '0;
        end else begin
            wgrant        <= '0;           // wgrant is a 1-cycle pulse
            last_grant_oh <= '0;
            mem_we        <= 1'b0;
            sh_we         <= 1'b0;
            if (x_wack) begin
                sh_we    <= 1'b1;          // the peer's DSMEM store
                sh_waddr <= x_waddr[9:2];
                sh_wdata <= {x_wdata, x_wdata};
                sh_wbe   <= x_waddr[1] ? 4'b1100 : 4'b0011;
            end
            if (any && !hold && sel_ok) begin
                if (space[sel] == 2'd2 || to_peer) begin
                    // taken by the L1 / the peer this cycle
                end else if (space[sel] == 2'd1) begin
                    sh_we    <= 1'b1;
                    sh_waddr <= waddr[sel][9:2];
                    sh_wdata <= {wdata[sel], wdata[sel]};
                    sh_wbe   <= waddr[sel][1] ? 4'b1100 : 4'b0011;
                end else begin
                    mem_we    <= 1'b1;     // commit this lane's write this cycle
                    mem_waddr <= waddr[sel][12:0];
                    mem_wdata <= wdata[sel][7:0];
                end
                wgrant[sel] <= 1'b1;       // ack the granted lane
                last_grant_oh[sel] <= 1'b1;
            end
        end
    end
endmodule
