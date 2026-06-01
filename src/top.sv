`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Tang Nano 20K top-level: a host-driven accelerator.
//
//   Mac --UART--> data_pipeline (uart_rx -> DMA -> main_memory)
//                      │ gpu_start (payload loaded)      ▲ gpu_done
//                      ▼                                 │
//                 GPU runs its kernel, LDR-ing data out of main_memory
//                      │
//                      └─ result -> LEDs + UART TX
//
// The GPU sits completely idle until the DMA finishes loading a payload and
// pulses gpu_start (no power-on auto-run). Everything is on one 27 MHz clock.
// ============================================================================
module top #(
    parameter PAYLOAD_BYTES = 793,       // 784-byte image + 9 signed weights
    parameter CLK_FREQ      = 27000000,  // for the UART bit timing (override in sim)
    parameter BAUD_RATE     = 115200
) (
    input  wire       clk,          // 27 MHz crystal  (PIN 4)
    input  wire       uart_rx_in,    // from host       (PIN 70)
    output wire       uart_tx_out,   // to host         (PIN 69)
    output wire [5:0] led            // active-LOW       (PIN 15..20)
);
    // ---- system power-on reset (initializes DMA / UART / memory) ----
    reg [3:0] por = 4'd0;
    wire por_done = &por;
    always @(posedge clk) if (!por_done) por <= por + 1'b1;
    wire sys_reset = !por_done;

    // ---- Host-to-Device pipeline ----
    wire        gpu_start, loading;
    wire [9:0]  mem_raddr;            // driven by the GPU's LSU arbiter
    wire [7:0]  mem_rdata;
    wire        done;                 // GPU finished a run
    wire [7:0]  result;

    data_pipeline #(
        .ADDR_BITS(10),
        .PAYLOAD_BYTES(PAYLOAD_BYTES),
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) pipe (
        .clk(clk), .reset(sys_reset),
        .uart_rx_in(uart_rx_in),
        .gpu_done(done),              // GPU done -> DMA re-arms for next frame
        .gpu_start(gpu_start),
        .loading(loading),
        .mem_raddr(mem_raddr),
        .mem_rdata(mem_rdata)
    );

    // ---- GPU run control: idle until a payload is ready ----
    // On gpu_start, briefly hold reset then release + enable for exactly one run.
    reg        armed  = 1'b0;
    reg [4:0]  runrst = 5'd0;
    always @(posedge clk) begin
        if (sys_reset)        begin armed <= 1'b0; runrst <= 5'd0; end
        else if (gpu_start)   begin armed <= 1'b1; runrst <= 5'd0; end // new run
        else if (armed && !(&runrst)) runrst <= runrst + 1'b1;
    end
    wire gpu_reset  = sys_reset || !armed || !(&runrst);
    wire gpu_enable = armed && (&runrst);

    // ---- the GPU ----
    gpu uut (
        .clk(clk),
        .reset(gpu_reset),
        .enable(gpu_enable),
        .result(result),
        .done(done),
        .debug_core_state(),
        .debug_instruction(),
        .operand_a(6'd0),             // operand-injection unused in host-driven mode
        .operand_b(6'd0),
        .mem_raddr(mem_raddr),
        .mem_rdata(mem_rdata)
    );

    // ========================================================================
    // Result reporting over UART TX: send `result` as ASCII decimal + CRLF on
    // the rising edge of `done` (one reply per completed run).
    // ========================================================================
    reg done_d = 1'b0;
    always @(posedge clk) done_d <= done;
    wire send_msg = done & ~done_d;

    reg [7:0] result_q = 8'd0;
    always @(posedge clk) if (send_msg) result_q <= result;

    wire [7:0] d100 = (result_q / 100);
    wire [7:0] d10  = (result_q / 10) % 8'd10;
    wire [7:0] d1   = (result_q % 8'd10);

    reg [2:0] idx;
    reg [7:0] tx_byte;
    always @(*) begin
        case (idx)
            3'd0:    tx_byte = 8'h30 + d100[3:0];
            3'd1:    tx_byte = 8'h30 + d10[3:0];
            3'd2:    tx_byte = 8'h30 + d1[3:0];
            3'd3:    tx_byte = 8'h0D;
            default: tx_byte = 8'h0A;
        endcase
    end

    wire uart_busy;
    reg  tx_start;
    reg  pending;
    localparam S_IDLE = 2'd0, S_REQ = 2'd1, S_BUSY = 2'd2, S_DONE = 2'd3;
    reg [1:0] mstate;
    always @(posedge clk) begin
        if (sys_reset) begin
            mstate <= S_IDLE; idx <= 3'd0; tx_start <= 1'b0; pending <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            if (send_msg) pending <= 1'b1;
            case (mstate)
                S_IDLE:  if (pending) begin pending <= 1'b0; idx <= 3'd0; mstate <= S_REQ; end
                S_REQ:   if (!uart_busy) begin tx_start <= 1'b1; mstate <= S_BUSY; end
                S_BUSY:  if (uart_busy) mstate <= S_DONE;
                S_DONE:  if (!uart_busy) begin
                             if (idx == 3'd4) mstate <= S_IDLE;
                             else begin idx <= idx + 3'd1; mstate <= S_REQ; end
                         end
            endcase
        end
    end

    uart_tx u_tx (
        .clk(clk), .reset(sys_reset),
        .data_in(tx_byte), .tx_start(tx_start),
        .tx_out(uart_tx_out), .tx_busy(uart_busy)
    );

    // ---- LEDs: loading status + done + low nibble of the result ----
    assign led = ~{loading, done, result[3:0]};

endmodule
