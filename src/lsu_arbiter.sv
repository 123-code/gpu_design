`default_nettype none
`timescale 1ns/1ns

// Serializes many thread LSUs' read requests onto main_memory's single read
// port. With multiple warps per core, requests arrive asynchronously (each warp
// is scheduled independently), so this is a CONTINUOUS server: whenever idle, it
// picks the lowest pending request, drives its address, waits one cycle for the
// BRAM read, then pulses that thread's ready with the data — and immediately
// looks for the next request. No batch snapshot / drain (that only worked when a
// single warp issued all its threads in lockstep).
//
// Per request: drive raddr -> wait 1 cycle (BRAM latency) -> 1-cycle ready pulse.
module lsu_arbiter #(
    parameter THREADS   = 4,
    parameter ADDR_BITS = 13
) (
    input  wire                 clk,
    input  wire                 reset,

    // ---- requests from the thread LSUs ----
    input  wire [THREADS-1:0]      req,                  // mem_valid[i]
    input  wire [ADDR_BITS-1:0]    addr  [THREADS-1:0],  // full mem_addr[i] (base+offset)

    // ---- single read port into main_memory ----
    output reg  [ADDR_BITS-1:0] mem_raddr,
    input  wire [7:0]           mem_rdata,

    // ---- responses back to the LSUs ----
    output reg  [THREADS-1:0]   ready,                   // mem_ready[i] (1-cycle pulse)
    output reg  [7:0]           rdata [THREADS-1:0]      // mem_read_data[i]
);
    // Index width must cover all THREADS (was hardcoded 2-bit = 4 threads).
    localparam IDX = (THREADS <= 1) ? 1 : $clog2(THREADS);

    localparam S_IDLE = 2'd0,
               S_WAIT = 2'd1,    // BRAM 1-cycle read latency
               S_RESP = 2'd2;    // data valid, pulse ready

    reg [1:0]       state;
    reg [IDX-1:0]   svc;         // thread currently being served

    // Lowest set request bit (iterate high->low so the lowest index wins).
    integer k;
    reg           any;
    reg [IDX-1:0] sel;
    always @(*) begin
        any = 1'b0; sel = '0;
        for (k = THREADS-1; k >= 0; k = k - 1)
            if (req[k]) begin sel = k[IDX-1:0]; any = 1'b1; end
    end

    integer j;
    always @(posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            ready     <= '0;
            mem_raddr <= '0;
            svc       <= '0;
            for (j = 0; j < THREADS; j = j + 1) rdata[j] <= 8'd0;
        end else begin
            ready <= '0;                           // ready is a 1-cycle pulse

            case (state)
                S_IDLE: if (any) begin
                            svc       <= sel;
                            mem_raddr <= addr[sel];   // full base+offset address
                            state     <= S_WAIT;
                        end

                S_WAIT: state <= S_RESP;              // wait out BRAM read latency

                S_RESP: begin
                            ready[svc] <= 1'b1;       // data valid this beat
                            rdata[svc] <= mem_rdata;
                            state      <= S_IDLE;      // look for the next request
                        end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
