`default_nettype none
`timescale 1ns/1ns

// Serializes the 4 thread LSUs' read requests onto main_memory's single read
// port. SIMT threads issue an LDR in lockstep, so up to 4 requests arrive at
// once (each with its own per-thread address in rs). This services them one at
// a time, returning each thread's data with a 1-cycle mem_ready pulse.
//
// Per request: drive raddr -> wait 1 cycle (BRAM read latency) -> pulse ready
// with the data. Snapshots the request mask, drains each bit, then waits for
// all valids to drop before re-arming (avoids re-serving a lingering valid).
module lsu_arbiter #(
    parameter THREADS   = 4,
    parameter ADDR_BITS = 12
) (
    input  wire                 clk,
    input  wire                 reset,

    // ---- requests from the thread LSUs ----
    input  wire [THREADS-1:0]      req,        // mem_valid[i]
    input  wire [ADDR_BITS-1:0]    addr  [THREADS-1:0],  // full mem_addr[i] (base+offset)

    // ---- single read port into main_memory ----
    output reg  [ADDR_BITS-1:0] mem_raddr,
    input  wire [7:0]           mem_rdata,

    // ---- responses back to the LSUs ----
    output reg  [THREADS-1:0]   ready,        // mem_ready[i] (1-cycle pulse)
    output reg  [7:0]           rdata [THREADS-1:0]   // mem_read_data[i]
);
    localparam S_IDLE  = 3'd0,
               S_SERVE = 3'd1,
               S_WAIT  = 3'd2,
               S_RESP  = 3'd3,
               S_DRAIN = 3'd4;

    reg [2:0]         state;
    reg [THREADS-1:0] pending;          // requests still to service this round
    reg [1:0]         svc;              // thread currently being served

    // Lowest set bit of `pending` (iterate high->low so the lowest wins).
    integer k;
    reg       any;
    reg [1:0] sel;
    always @(*) begin
        any = 1'b0; sel = 2'd0;
        for (k = THREADS-1; k >= 0; k = k - 1)
            if (pending[k]) begin sel = k[1:0]; any = 1'b1; end
    end

    integer j;
    always @(posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            pending   <= '0;
            ready     <= '0;
            mem_raddr <= '0;
            svc       <= 2'd0;
            for (j = 0; j < THREADS; j = j + 1) rdata[j] <= 8'd0;
        end else begin
            ready <= '0;                      // ready is a 1-cycle pulse

            case (state)
                S_IDLE: if (|req) begin
                            pending <= req;   // snapshot this LDR's requests
                            state   <= S_SERVE;
                        end

                S_SERVE: if (any) begin
                            svc       <= sel;
                            mem_raddr <= addr[sel];        // full base+offset address
                            state     <= S_WAIT;
                        end else begin
                            state <= S_DRAIN;          // all bits serviced
                        end

                S_WAIT: state <= S_RESP;               // BRAM 1-cycle read latency

                S_RESP: begin
                            ready[svc]   <= 1'b1;      // data valid this beat
                            rdata[svc]   <= mem_rdata;
                            pending[svc] <= 1'b0;       // mark serviced
                            state        <= S_SERVE;    // next pending thread
                        end

                S_DRAIN: if (~|req) state <= S_IDLE;    // wait for LSUs to drop valid

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
