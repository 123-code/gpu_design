`default_nettype none
`timescale 1ns/1ns

// Serializes many thread LSUs' read requests onto the core's memory read
// ports. With multiple warps per core, requests arrive asynchronously (each warp
// is scheduled independently), so this is a CONTINUOUS server: whenever idle, it
// picks the lowest pending request, drives its address, waits one cycle for the
// BRAM read, then pulses that thread's ready with the data — and immediately
// looks for the next request. No batch snapshot / drain (that only worked when a
// single warp issued all its threads in lockstep).
//
// Two address spaces share the server:
//   space 0  main (data) memory, byte-wide         -> mem_raddr / mem_rdata
//   space 1  shared memory, 32-bit words, read as  -> sh_raddr  / sh_rdata
//            the 16-bit halfword at byte addr[1]
// Both are 1-cycle BRAMs, so the protocol is the same; only the port and the
// returned width differ. `hold` stops new requests from being accepted (the
// current one still completes): another unit is borrowing a read port (the
// tensor core the shared one, the copy engine the main one). `sh_busy` /
// `mem_busy` tell it when its port is free.
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
    // Per-thread request fields, packed (thread i at [i*W +: W]): yosys does
    // not take unpacked-array ports, so the flow needs no sv2v for these.
    input  wire [THREADS*ADDR_BITS-1:0] addr_p,          // full mem_addr[i] (base+offset)
    input  wire [THREADS*2-1:0]         space_p,         // 0 main, 1 shared, 2 global

    input  wire                 hold,                    // accept no new request
    output wire                 sh_busy,                 // a shared read is in flight
    output wire                 mem_busy,                // a main-memory read is in flight

    // ---- global memory (the core's L1): variable latency, req held until ack ----
    output reg                  g_req,
    output reg  [15:0]          g_addr,
    input  wire                 g_ack,
    input  wire [15:0]          g_rdata,

    // ---- the PEER core's shared memory (DSMEM: LDS with address bit 10) ----
    output reg                  r_req,
    output reg  [7:0]           r_addr,                  // peer word address
    input  wire                 r_ack,                   // 1-cycle, with r_data
    input  wire [31:0]          r_data,

    // ---- main memory read port ----
    output reg  [12:0]          mem_raddr,
    input  wire [7:0]           mem_rdata,

    // ---- shared memory read port (word address) ----
    output reg  [7:0]           sh_raddr,
    input  wire [31:0]          sh_rdata,

    // ---- responses back to the LSUs ----
    output reg  [THREADS-1:0]   ready,                   // mem_ready[i] (1-cycle pulse)
    output wire [THREADS*16-1:0] rdata_p                 // mem_read_data[i]
);
    wire [ADDR_BITS-1:0] addr  [THREADS-1:0];
    wire [1:0]           space [THREADS-1:0];
    reg  [15:0]          rdata [THREADS-1:0];
    genvar gp;
    generate for (gp = 0; gp < THREADS; gp = gp + 1) begin : unpack
        assign addr[gp]  = addr_p[gp*ADDR_BITS +: ADDR_BITS];
        assign space[gp] = space_p[gp*2 +: 2];
        assign rdata_p[gp*16 +: 16] = rdata[gp];
    end endgenerate
    // Index width must cover all THREADS (was hardcoded 2-bit = 4 threads).
    localparam IDX = (THREADS <= 1) ? 1 : $clog2(THREADS);

    localparam S_IDLE = 2'd0,
               S_WAIT = 2'd1,    // BRAM 1-cycle read latency
               S_RESP = 2'd2,    // data valid, pulse ready
               S_GWAIT = 2'd3,   // global load: wait for the L1
               S_RWAIT = 3'd4;   // DSMEM load: wait for the peer core

    reg [2:0]       state;
    reg [IDX-1:0]   svc;         // thread currently being served
    reg [1:0]       svc_space;   // ... and which memory it reads
    reg             svc_hi;      // shared: upper halfword of the word

    // (a DSMEM load waits on the PEER's port, so it leaves ours free --
    // otherwise two cores loading from each other would deadlock)
    assign sh_busy  = (state == S_WAIT || state == S_RESP) && (svc_space == 2'd1);
    assign mem_busy = (state != S_IDLE) && (svc_space == 2'd0);

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
            sh_raddr  <= 8'd0;
            svc       <= '0;
            svc_space <= 2'd0;
            svc_hi    <= 1'b0;
            g_req     <= 1'b0;
            g_addr    <= 16'd0;
            r_req     <= 1'b0;
            r_addr    <= 8'd0;
            for (j = 0; j < THREADS; j = j + 1) rdata[j] <= 16'd0;
        end else begin
            ready <= '0;                           // ready is a 1-cycle pulse

            case (state)
                S_IDLE: if (any && !hold) begin
                            svc       <= sel;
                            svc_space <= space[sel];
                            svc_hi    <= addr[sel][1];
                            if (space[sel] == 2'd1 && addr[sel][10]) begin
                                r_req  <= 1'b1;               // LDS from the peer
                                r_addr <= addr[sel][9:2];
                                state  <= S_RWAIT;
                            end else if (space[sel] == 2'd2) begin
                                g_req  <= 1'b1;               // LDG -> L1
                                g_addr <= addr[sel][15:0];
                                state  <= S_GWAIT;
                            end else begin
                                if (space[sel] == 2'd1) sh_raddr  <= addr[sel][9:2];
                                else                    mem_raddr <= addr[sel][12:0];
                                state     <= S_WAIT;
                            end
                        end

                S_WAIT: state <= S_RESP;              // wait out BRAM read latency

                S_RESP: begin
                            ready[svc] <= 1'b1;       // data valid this beat
                            rdata[svc] <= (svc_space == 2'd0) ? {8'd0, mem_rdata}
                                        : svc_hi     ? sh_rdata[31:16]
                                        :              sh_rdata[15:0];
                            state      <= S_IDLE;      // look for the next request
                        end

                S_RWAIT: if (r_ack) begin
                            r_req      <= 1'b0;
                            ready[svc] <= 1'b1;
                            rdata[svc] <= svc_hi ? r_data[31:16] : r_data[15:0];
                            state      <= S_IDLE;
                        end

                S_GWAIT: if (g_ack) begin
                            g_req      <= 1'b0;
                            ready[svc] <= 1'b1;
                            rdata[svc] <= g_rdata;
                            state      <= S_IDLE;
                        end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
