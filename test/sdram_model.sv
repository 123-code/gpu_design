`default_nettype none
`timescale 1ns/1ns

// Behavioural model of the GW2AR-18's in-package SDR SDRAM (2M x 32: 4 banks
// x 2048 rows x 256 columns), for simulation only.
//
// It decodes the standard command set on its own clock (the controller runs
// it 180 degrees out of phase with sys_clk, as the board does), honours the
// mode register's burst length and CAS latency, applies DQM byte masks on
// writes, and drives read data CL clocks after READ. It also CHECKS the
// protocol, so a controller bug fails the simulation instead of silently
// reading garbage: access before LOAD MODE, READ/WRITE to a closed bank,
// ACTIVE to an open bank, ACTIVE->READ/WRITE sooner than tRCD, PRECHARGE->
// ACTIVE sooner than tRP, ACTIVE->ACTIVE (same bank) sooner than tRC, and a
// missed refresh deadline. Violations print "SDRAM PROTOCOL" and count in
// `violations`.
//
// Storage is sparse: only the low ADDR_BITS of the {bank,row,col} word
// address are kept (64K words by default), which is plenty for the tests.
module sdram_model #(
    parameter ADDR_BITS   = 16,
    parameter T_RCD       = 1,       // in clocks of this model's clock
    parameter T_RP        = 1,
    parameter T_RC        = 3,
    parameter T_REFI_MAX  = 1000000  // refresh deadline (clocks), checked
) (
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [1:0]  ba,
    input  wire [10:0] addr,
    input  wire [3:0]  dqm,
    inout  wire [31:0] dq
);
    reg [31:0] mem [0:(1<<ADDR_BITS)-1];
    integer i;
    initial for (i = 0; i < (1<<ADDR_BITS); i = i + 1) mem[i] = 32'd0;

    integer violations = 0;
    integer reads = 0, writes = 0, activates = 0, refreshes = 0;

    reg        mode_set = 1'b0;
    reg [2:0]  cl = 3'd2;
    reg [3:0]  bl = 4'd1;
    reg        open_  [0:3];
    reg [10:0] row_   [0:3];
    integer    t_act  [0:3];             // cycle of last ACTIVE
    integer    t_pre  [0:3];             // cycle the bank became precharged
    integer    cyc = 0;
    integer    last_ref = 0;
    initial for (i = 0; i < 4; i = i + 1) begin
        open_[i] = 1'b0; row_[i] = 0; t_act[i] = -100; t_pre[i] = -100;
    end

    // read pipeline: stage k = data to drive k clocks from now
    reg [31:0] rd_data [0:7];
    reg        rd_v    [0:7];
    initial for (i = 0; i < 8; i = i + 1) rd_v[i] = 1'b0;
    reg [31:0] dq_out;
    reg        dq_oe = 1'b0;
    assign #1 dq = dq_oe ? dq_out : 32'bz;

    // write burst in progress
    integer    wr_left = 0;
    reg [ADDR_BITS-1:0] wr_addr;
    reg        wr_ap;  reg [1:0] wr_bank;
    integer    rd_ap_cyc [0:3];
    initial for (i = 0; i < 4; i = i + 1) rd_ap_cyc[i] = -1;

    function [ADDR_BITS-1:0] waddr(input [1:0] b, input [10:0] r, input [7:0] c);
        reg [20:0] full;
        begin full = {r, b, c}; waddr = full[ADDR_BITS-1:0]; end
    endfunction

    task violation(input [8*64-1:0] what);
        begin
            violations = violations + 1;
            $display("SDRAM PROTOCOL @%0t: %0s", $time, what);
        end
    endtask

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
    integer b, k;
    always @(posedge clk) begin
        cyc = cyc + 1;
        // drive the read pipeline
        dq_oe  <= rd_v[0];
        dq_out <= rd_data[0];
        for (k = 0; k < 7; k = k + 1) begin rd_v[k] = rd_v[k+1]; rd_data[k] = rd_data[k+1]; end
        rd_v[7] = 1'b0;
        // auto-precharge after a read burst
        for (b = 0; b < 4; b = b + 1)
            if (rd_ap_cyc[b] == cyc) begin open_[b] = 1'b0; t_pre[b] = cyc; rd_ap_cyc[b] = -1; end

        // continue a write burst
        if (wr_left > 0) begin
            if (!dqm[0]) mem[wr_addr][7:0]   = dq[7:0];
            if (!dqm[1]) mem[wr_addr][15:8]  = dq[15:8];
            if (!dqm[2]) mem[wr_addr][23:16] = dq[23:16];
            if (!dqm[3]) mem[wr_addr][31:24] = dq[31:24];
            wr_addr = {wr_addr[ADDR_BITS-1:2], wr_addr[1:0] + 2'd1};
            wr_left = wr_left - 1;
            if (wr_left == 0 && wr_ap) begin open_[wr_bank] = 1'b0; t_pre[wr_bank] = cyc + 2; end
        end

        if (cyc - last_ref > T_REFI_MAX && mode_set) begin
            violation("refresh deadline missed"); last_ref = cyc;
        end

        if (cke && !cs_n) case (cmd)
            4'b0011: begin // ACTIVE
                if (!mode_set) violation("ACTIVE before LOAD MODE");
                if (open_[ba]) violation("ACTIVE to an open bank");
                if (cyc - t_pre[ba] < T_RP) violation("PRECHARGE->ACTIVE < tRP");
                if (cyc - t_act[ba] < T_RC) violation("ACTIVE->ACTIVE < tRC");
                open_[ba] = 1'b1; row_[ba] = addr; t_act[ba] = cyc;
                activates = activates + 1;
            end
            4'b0101: begin // READ
                if (!open_[ba]) violation("READ to a closed bank");
                if (cyc - t_act[ba] < T_RCD) violation("ACTIVE->READ < tRCD");
                for (k = 0; k < bl; k = k + 1) begin
                    // stage 0 is driven right after the NEXT edge, so a beat
                    // queued at cl-2 is on the bus from edge CL-1 to edge CL
                    rd_v[cl - 2 + k]    = 1'b1;
                    rd_data[cl - 2 + k] = mem[waddr(ba, row_[ba], {addr[7:2], addr[1:0] + k[1:0]})];
                end
                if (addr[10]) rd_ap_cyc[ba] = cyc + bl;
                reads = reads + 1;
            end
            4'b0100: begin // WRITE (first beat now)
                if (!open_[ba]) violation("WRITE to a closed bank");
                if (cyc - t_act[ba] < T_RCD) violation("ACTIVE->WRITE < tRCD");
                wr_addr = waddr(ba, row_[ba], addr[7:0]);
                if (!dqm[0]) mem[wr_addr][7:0]   = dq[7:0];
                if (!dqm[1]) mem[wr_addr][15:8]  = dq[15:8];
                if (!dqm[2]) mem[wr_addr][23:16] = dq[23:16];
                if (!dqm[3]) mem[wr_addr][31:24] = dq[31:24];
                wr_addr = {wr_addr[ADDR_BITS-1:2], wr_addr[1:0] + 2'd1};
                wr_left = bl - 1; wr_ap = addr[10]; wr_bank = ba;
                if (wr_left == 0 && wr_ap) begin open_[ba] = 1'b0; t_pre[ba] = cyc + 2; end
                writes = writes + 1;
            end
            4'b0010: begin // PRECHARGE (A10 = all banks)
                for (b = 0; b < 4; b = b + 1)
                    if (addr[10] || b == ba) begin open_[b] = 1'b0; t_pre[b] = cyc; end
            end
            4'b0001: begin // AUTO REFRESH
                for (b = 0; b < 4; b = b + 1)
                    if (open_[b]) violation("REFRESH with a bank open");
                last_ref = cyc;
                refreshes = refreshes + 1;
            end
            4'b0000: begin // LOAD MODE
                for (b = 0; b < 4; b = b + 1)
                    if (open_[b]) violation("LOAD MODE with a bank open");
                bl = (addr[2:0] == 3'd0) ? 1 : (addr[2:0] == 3'd1) ? 2 : (addr[2:0] == 3'd2) ? 4 : 8;
                cl = addr[6:4];
                mode_set = 1'b1;
            end
            default: ; // NOP / burst stop: unused
        endcase
    end
endmodule
