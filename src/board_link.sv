`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Board-to-board link (NVLink, at a scale of two GPIO wires).
//
// An NVL72 rack is 72 Blackwell GPUs whose NVLink ports let any GPU store
// straight into another GPU's memory. Here two Tang Nano 20K boards are
// joined by a pair of wires (link_tx -> the other board's link_rx), and a
// GPU global store whose address has bit 15 set goes over the link and
// lands in the OTHER board's SDRAM, at the same address with bit 15 clear.
//
// Remote stores are posted: the store is queued here (8-entry FIFO) and the
// thread moves on. Each one travels as a 5-byte packet
//     0xA5, addr[7:0], addr[15:8], data[7:0], data[15:8]
// framed like a UART byte (start bit, 8 data bits, stop bit) at DIV system
// clocks per bit: 13.5 Mbit/s at 54 MHz with DIV = 4, roughly eight orders
// of magnitude short of NVLink 5, but the same idea. The receiver turns each
// packet into a masked halfword write to its own SDRAM.
//
// Remote loads are not supported (they read as 0): like NVLink stores plus
// a barrier, the pattern is "push your data to the peer, then synchronize".
// `idle` drops while anything is queued or on the wire, and top.sv holds
// `done` low until it rises, so a host that sees the run finish knows every
// remote store has left the board.
// ============================================================================
module board_link #(
    parameter DIV = 4                    // system clocks per link bit
) (
    input  wire        clk,
    input  wire        reset,

    // remote stores to send (taken when s_ack pulses)
    input  wire        s_req,
    input  wire [15:0] s_addr,           // byte address (halfword aligned)
    input  wire [15:0] s_data,
    output wire        s_ack,
    output wire        idle,

    // stores received from the peer -> our SDRAM (mem_arb client protocol)
    output reg         r_req,
    output reg  [20:0] r_addr,
    output reg  [31:0] r_wdata,
    output reg  [3:0]  r_wbe,
    input  wire        r_ack,
    input  wire        r_done,

    output wire        link_tx,
    input  wire        link_rx,

    output reg  [15:0] sent,             // packets sent / received (for tests)
    output reg  [15:0] received
);
    // ---------------- transmit ----------------
    reg [31:0] fifo [0:7];
    reg [3:0]  wr_p, rd_p;               // 4-bit pointers: full when they differ by 8
    wire       empty = (wr_p == rd_p);
    wire       full  = (wr_p[2:0] == rd_p[2:0]) && (wr_p[3] != rd_p[3]);
    assign s_ack = s_req && !full;

    reg  [2:0]  tx_idx;                  // byte of the packet being sent (0..4)
    reg         tx_active;
    reg  [31:0] tx_pkt;
    reg         tx_start;
    reg  [7:0]  tx_byte;
    wire        tx_busy;

    uart_tx #(.BAUD_LIMIT(DIV)) u_ltx (
        .clk(clk), .reset(reset), .data_in(tx_byte), .tx_start(tx_start),
        .tx_out(link_tx), .tx_busy(tx_busy)
    );

    reg tx_wait;                         // a byte was started; wait for busy to rise/fall
    reg tx_seen_busy;
    assign idle = empty && !tx_active;

    always @(posedge clk) begin
        if (reset) begin
            wr_p <= 4'd0; rd_p <= 4'd0;
            tx_active <= 1'b0; tx_start <= 1'b0; tx_wait <= 1'b0; tx_seen_busy <= 1'b0;
            sent <= 16'd0;
        end else begin
            tx_start <= 1'b0;
            if (s_ack) begin
                fifo[wr_p[2:0]] <= {s_data, s_addr};
                wr_p <= wr_p + 4'd1;
            end
            if (!tx_active) begin
                if (!empty) begin
                    tx_pkt    <= fifo[rd_p[2:0]];
                    rd_p      <= rd_p + 4'd1;
                    tx_active <= 1'b1;
                    tx_idx    <= 3'd0;
                end
            end else if (!tx_wait) begin
                tx_byte  <= (tx_idx == 3'd0) ? 8'hA5
                          : (tx_idx == 3'd1) ? tx_pkt[7:0]
                          : (tx_idx == 3'd2) ? tx_pkt[15:8]
                          : (tx_idx == 3'd3) ? tx_pkt[23:16]
                          :                    tx_pkt[31:24];
                tx_start <= 1'b1;
                tx_wait  <= 1'b1;
                tx_seen_busy <= 1'b0;
            end else begin
                if (tx_busy) tx_seen_busy <= 1'b1;
                if (tx_seen_busy && !tx_busy) begin       // byte fully on the wire
                    tx_wait <= 1'b0;
                    if (tx_idx == 3'd4) begin
                        tx_active <= 1'b0;
                        sent <= sent + 16'd1;
                    end else
                        tx_idx <= tx_idx + 3'd1;
                end
            end
        end
    end

    // ---------------- receive ----------------
    wire [7:0] rx_byte;
    wire       rx_valid;
    uart_rx #(.CLK_FREQ(DIV), .BAUD_RATE(1)) u_lrx (
        .clk(clk), .reset(reset), .rx_in(link_rx), .rx_byte(rx_byte), .rx_valid(rx_valid)
    );

    reg [2:0]  rx_idx;                   // 0 = hunting for 0xA5, 1..4 = payload bytes
    reg [31:0] rx_pkt;
    reg        r_busy;                   // an SDRAM write is in progress
    reg        pend;                     // a whole packet is waiting for the SDRAM
    reg [31:0] pend_pkt;

    always @(posedge clk) begin
        if (reset) begin
            rx_idx <= 3'd0; r_req <= 1'b0; r_busy <= 1'b0; pend <= 1'b0;
            received <= 16'd0;
        end else begin
            if (rx_valid) begin
                if (rx_idx == 3'd0) begin
                    if (rx_byte == 8'hA5) rx_idx <= 3'd1;
                end else begin
                    rx_pkt[(rx_idx - 3'd1) * 8 +: 8] <= rx_byte;
                    if (rx_idx == 3'd4) begin
                        pend     <= 1'b1;
                        pend_pkt <= {rx_byte, rx_pkt[23:0]};
                        rx_idx   <= 3'd0;
                        received <= received + 16'd1;
                    end else
                        rx_idx <= rx_idx + 3'd1;
                end
            end
            // one halfword store per packet, to our own SDRAM (bit 15 cleared)
            if (!r_busy && pend) begin
                r_req   <= 1'b1;
                r_addr  <= {8'd0, pend_pkt[14:2]};
                r_wdata <= {pend_pkt[31:16], pend_pkt[31:16]};
                r_wbe   <= pend_pkt[1] ? 4'b1100 : 4'b0011;
                r_busy  <= 1'b1;
                pend    <= 1'b0;
            end
            if (r_ack)  r_req  <= 1'b0;
            if (r_done) r_busy <= 1'b0;
        end
    end
endmodule

// ----------------------------------------------------------------------------
// Sits between a core's global-memory port and the SDRAM arbiter. Requests
// whose byte address has bit 15 set (word address bit 13) are REMOTE: a
// store goes to the board link (acknowledged once queued, so it stays
// posted), a load completes at once with zeros. Everything else passes
// straight through to the SDRAM.
// ----------------------------------------------------------------------------
module link_router (
    input  wire        clk,
    input  wire        reset,

    input  wire        c_req,
    input  wire        c_we,
    input  wire [20:0] c_addr,
    input  wire [31:0] c_wdata,
    input  wire [3:0]  c_wbe,
    output wire        c_ack,
    output wire        c_rvalid,
    output wire        c_done,
    output wire [31:0] c_rdata,

    output wire        a_req,
    input  wire        a_ack,
    input  wire        a_rvalid,
    input  wire        a_done,
    input  wire [31:0] a_rdata,

    output wire        l_req,
    output wire [15:0] l_addr,
    output wire [15:0] l_data,
    input  wire        l_ack
);
    localparam S_IDLE = 2'd0, S_ACK = 2'd1, S_BEAT = 2'd2, S_DONE = 2'd3;
    reg [1:0] state;
    reg [1:0] beat;
    reg       was_we;
    wire remote = c_addr[13];

    assign a_req  = c_req && !remote && state == S_IDLE;
    assign l_req  = c_req && remote && c_we && state == S_IDLE;
    assign l_addr = {c_addr[13:0], c_wbe[2], 1'b0};
    assign l_data = c_wbe[2] ? c_wdata[31:16] : c_wdata[15:0];

    assign c_ack    = a_ack    || state == S_ACK;
    assign c_rvalid = a_rvalid || state == S_BEAT;
    assign c_done   = a_done   || state == S_DONE;
    assign c_rdata  = (state == S_BEAT) ? 32'd0 : a_rdata;

    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE; beat <= 2'd0; was_we <= 1'b0;
        end else case (state)
            S_IDLE: if (c_req && remote && (!c_we || l_ack)) begin
                was_we <= c_we;
                state  <= S_ACK;
            end
            S_ACK:  begin beat <= 2'd0; state <= was_we ? S_DONE : S_BEAT; end
            S_BEAT: begin beat <= beat + 2'd1; if (beat == 2'd3) state <= S_DONE; end
            S_DONE: state <= S_IDLE;
        endcase
    end
endmodule
