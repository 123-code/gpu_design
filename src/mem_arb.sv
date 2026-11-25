`default_nettype none
`timescale 1ns/1ns

// N-way arbiter in front of one memory-request port (sdram_ctrl's, or a
// core's global port). Client protocol, same on both sides:
//   hold req (with we/addr/wdata/wbe stable) until ack;
//   then rvalid pulses (reads: 4 beats of rdata), then a done pulse.
// The downstream port latches a request on the edge it sees req, and acks
// one cycle later; sel_d remembers whose request that was. The winner owns
// the port until its done. Round robin, so no client starves.
module mem_arb #(
    parameter N = 2
) (
    input  wire              clk,
    input  wire              reset,

    input  wire [N-1:0]      c_req,
    input  wire [N-1:0]      c_we,
    input  wire [20:0]       c_addr  [N-1:0],
    input  wire [31:0]       c_wdata [N-1:0],
    input  wire [3:0]        c_wbe   [N-1:0],
    output wire [N-1:0]      c_ack,
    output wire [N-1:0]      c_rvalid,
    output wire [N-1:0]      c_done,

    output wire              m_req,
    output wire              m_we,
    output wire [20:0]       m_addr,
    output wire [31:0]       m_wdata,
    output wire [3:0]        m_wbe,
    input  wire              m_ack,
    input  wire              m_rvalid,
    input  wire              m_done
);
    localparam IW = (N <= 1) ? 1 : $clog2(N);

    reg          busy;          // a request was taken and is not done
    reg          taken;         // m_req was high last cycle (downstream may have latched)
    reg [IW-1:0] owner, sel_d, last;

    // round robin: first requester after `last`
    reg [IW-1:0] sel;
    reg          any;
    integer k, idx;
    always @(*) begin
        any = 1'b0; sel = '0;
        for (k = N; k >= 1; k = k - 1) begin
            idx = (last + k) % N;
            if (c_req[idx]) begin any = 1'b1; sel = idx[IW-1:0]; end
        end
    end

    // While busy, keep presenting the owner's request; the downstream ignores
    // it (it is mid-operation) and the owner has already dropped req anyway.
    wire [IW-1:0] cur = busy ? owner : sel;
    assign m_req   = !busy && any;
    assign m_we    = c_we[cur];
    assign m_addr  = c_addr[cur];
    assign m_wdata = c_wdata[cur];
    assign m_wbe   = c_wbe[cur];

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : route
            assign c_ack[g]    = m_ack    && (sel_d == g);
            assign c_rvalid[g] = m_rvalid && busy && (owner == g);
            assign c_done[g]   = m_done   && busy && (owner == g);
        end
    endgenerate

    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0; owner <= '0; sel_d <= '0; last <= '0; taken <= 1'b0;
        end else begin
            sel_d <= sel;
            if (m_ack) begin
                busy  <= 1'b1;
                owner <= sel_d;
                last  <= sel_d;
            end
            if (m_done) busy <= 1'b0;
        end
    end
endmodule
