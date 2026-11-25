`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Controller for the GW2AR-18's in-package 64 Mbit SDR SDRAM (2M x 32).
//
// This is the "HBM" of the design: the one large memory, outside the
// compute cores, that every core and the host share. Closed-page policy, two
// operations, both with auto-precharge:
//
//   line read : ACTIVE, tRCD, READ (burst 4), CAS latency 2 -> 4 words
//               (one 16-byte cache line / TMA chunk)
//   word write: ACTIVE, tRCD, WRITE, the first beat carries the data with
//               DQM = ~byte_enables, the other three beats are masked
//
// The mode register is set once (burst length 4, sequential, CL 2). Refresh
// is issued every REF_INTERVAL cycles between operations; init waits
// INIT_CYCLES (200 us on the board) before PRECHARGE ALL, 2x AUTO REFRESH,
// LOAD MODE. The SDRAM clock is sys_clk inverted (top.sv), so commands
// launched on a sys_clk edge are sampled half a cycle later, and read data
// for a READ launched at edge E is sampled at edge E+CL+beat.
//
// Address: word address [20:0] = {row[10:0], bank[1:0], col[7:0]}.
// Clients see req/ack (ack = request taken), then rvalid x4 (reads) and a
// done pulse when the operation, including precharge, is over.
// ============================================================================
module sdram_ctrl #(
    parameter INIT_CYCLES  = 10800,      // 200 us at 54 MHz
    parameter REF_INTERVAL = 750         // < 15.6 us (4096 rows / 64 ms)
) (
    input  wire        clk,
    input  wire        reset,

    input  wire        req,
    input  wire        we,
    input  wire [20:0] addr,             // word address (reads: line aligned)
    input  wire [31:0] wdata,
    input  wire [3:0]  wbe,
    output reg         ack,
    output reg         rvalid,
    output reg  [31:0] rdata,
    output reg         done,
    output wire        init_done,

    // SDRAM pins (names follow the Tang Nano 20K's embedded-SDRAM ports)
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output reg  [1:0]  sdram_ba,
    output reg  [10:0] sdram_addr,
    output reg  [3:0]  sdram_dqm,
    inout  wire [31:0] sdram_dq
);
    localparam CL = 2;
    localparam C_NOP = 4'b0111, C_ACT = 4'b0011, C_READ = 4'b0101, C_WRITE = 4'b0100,
               C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;

    reg [3:0]  cmd;
    reg [31:0] dq_out;
    reg        dq_oe;
    assign {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} = cmd;
    assign sdram_cke = 1'b1;
    assign sdram_dq  = dq_oe ? dq_out : 32'bz;

    localparam S_INIT = 4'd0, S_IPRE = 4'd1, S_IREF = 4'd2, S_IMRS = 4'd3,
               S_IDLE = 4'd4, S_REF = 4'd5, S_ACT = 4'd6, S_RD = 4'd7,
               S_WR = 4'd8, S_TAIL = 4'd9;
    reg [3:0]  state;
    reg [15:0] cnt;
    reg [15:0] ref_cnt;
    reg [1:0]  iref;
    reg        op_we;
    reg [20:0] op_addr;
    reg [31:0] op_wdata;
    reg [3:0]  op_wbe;

    assign init_done = (state >= S_IDLE);

    always @(posedge clk) begin
        if (reset) begin
            state   <= S_INIT;
            cnt     <= 16'd0;
            ref_cnt <= 16'd0;
            cmd     <= C_NOP;
            dq_oe   <= 1'b0;
            sdram_dqm <= 4'b1111;
            sdram_ba  <= 2'd0;
            sdram_addr <= 11'd0;
            ack <= 1'b0; rvalid <= 1'b0; done <= 1'b0;
            iref <= 2'd0;
        end else begin
            cmd    <= C_NOP;
            ack    <= 1'b0;
            rvalid <= 1'b0;
            done   <= 1'b0;
            cnt    <= cnt + 16'd1;
            if (state >= S_IDLE) ref_cnt <= ref_cnt + 16'd1;

            case (state)
                S_INIT: if (cnt >= INIT_CYCLES) begin
                    cmd <= C_PRE; sdram_addr[10] <= 1'b1;       // precharge all
                    cnt <= 16'd0; state <= S_IPRE;
                end
                S_IPRE: if (cnt >= 2) begin
                    cmd <= C_REF; cnt <= 16'd0; iref <= 2'd1; state <= S_IREF;
                end
                S_IREF: if (cnt >= 8) begin
                    if (iref == 2'd1) begin
                        cmd <= C_REF; cnt <= 16'd0; iref <= 2'd2;
                    end else begin
                        // mode: burst 4 (010), sequential, CL 2 (010), burst writes
                        cmd <= C_MRS; sdram_ba <= 2'd0;
                        sdram_addr <= 11'b0_0_00_010_0_010;  // A9 burst wr, CL[6:4]=2, A3 seq, BL[2:0]=4
                        cnt <= 16'd0; state <= S_IMRS;
                    end
                end
                S_IMRS: if (cnt >= 3) state <= S_IDLE;

                S_IDLE: begin
                    if (ref_cnt >= REF_INTERVAL) begin
                        cmd <= C_REF; ref_cnt <= 16'd0; cnt <= 16'd0; state <= S_REF;
                    end else if (req) begin
                        ack      <= 1'b1;
                        op_we    <= we;
                        op_addr  <= addr;
                        op_wdata <= wdata;
                        op_wbe   <= wbe;
                        cmd        <= C_ACT;
                        sdram_ba   <= addr[9:8];
                        sdram_addr <= addr[20:10];
                        cnt <= 16'd0; state <= S_ACT;
                    end
                end
                S_REF: if (cnt >= 8) state <= S_IDLE;

                // tRCD: the READ/WRITE goes out two cycles after the ACTIVE
                S_ACT: if (cnt >= 1) begin
                    sdram_ba   <= op_addr[9:8];
                    sdram_addr <= {3'b100, op_addr[7:0]};       // A10 = auto-precharge
                    cnt <= 16'd0;
                    if (op_we) begin
                        cmd       <= C_WRITE;
                        dq_oe     <= 1'b1;
                        dq_out    <= op_wdata;
                        sdram_dqm <= ~op_wbe;
                        state     <= S_WR;
                    end else begin
                        cmd       <= C_READ;
                        sdram_dqm <= 4'b0000;
                        state     <= S_RD;
                    end
                end
                // Beat k of a READ launched at edge E is sampled at E+CL+k.
                // cnt counts edges since E (it was zeroed at E): beat k is
                // on the bus when cnt == CL-1+k here.
                S_RD: begin
                    if (cnt >= CL - 1 && cnt <= CL + 2) begin
                        rvalid <= 1'b1;
                        rdata  <= sdram_dq;
                    end
                    if (cnt == CL + 2) begin cnt <= 16'd0; state <= S_TAIL; end
                end
                // masked beats 1..3, then release the bus
                S_WR: begin
                    sdram_dqm <= 4'b1111;
                    if (cnt == 2) begin
                        dq_oe <= 1'b0; cnt <= 16'd0; state <= S_TAIL;
                    end
                end
                // auto-precharge (tWR + tRP) before the next ACTIVE
                S_TAIL: if (cnt >= 3) begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
