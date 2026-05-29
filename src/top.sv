`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Tang Nano 20K top-level for tiny-gpu, with UART result reporting.
//
//   - GPU runs on a divided ~13 kHz clock (timing-safe), computes 5*3 = 15.
//   - When done, LED5 + LED3..0 show the result (1111 = 15).
//   - The result is transmitted over UART (115200 8N1, PIN 69) as ASCII
//     decimal digits + CRLF, e.g. "015\r\n", and RE-SENT about every 0.6 s
//     so you can open the serial monitor at any time and still see it.
// ============================================================================
module top (
    input  wire       clk,          // 27 MHz crystal  (PIN 4)
    output wire       uart_tx_out,   // UART TX -> USB-serial (PIN 69)
    output wire [5:0] led            // 6 onboard LEDs, active-LOW (PIN 15..20)
);
    // ---- divide 27 MHz -> ~13 kHz GPU clock ----
    reg [10:0] div = 11'd0;
    always @(posedge clk) div <= div + 1'b1;
    wire gpu_clk = div[10];

    // ---- power-on reset (on the GPU clock) ----
    reg [3:0] por = 4'd0;
    wire por_done = &por;
    always @(posedge gpu_clk)
        if (!por_done) por <= por + 1'b1;

    wire reset  = !por_done;   // active-HIGH
    wire enable = por_done;

    // ---- the GPU (slow clock) ----
    wire [7:0] result;
    wire       done;

    gpu uut (
        .clk(gpu_clk),
        .reset(reset),
        .enable(enable),
        .result(result),
        .done(done),
        .debug_core_state(),
        .debug_instruction()
    );

    // ========================================================================
    // Everything below runs in the fast 27 MHz domain (matches uart baud).
    // ========================================================================

    // Synchronize the slow-domain 'done' into the fast domain (2 FFs).
    reg done_s1 = 1'b0, done_s2 = 1'b0;
    always @(posedge clk) begin
        done_s1 <= done;
        done_s2 <= done_s1;
    end

    // Periodic ~0.6 s tick (2^24 / 27 MHz). Re-sends the result so you can
    // attach the serial monitor at any time and still catch it.
    reg [23:0] hb = 24'd0;
    always @(posedge clk) hb <= hb + 1'b1;
    wire send_msg = (hb == 24'd0);

    // Decimal digits of the result (0..255).
    wire [7:0] d100 = (result / 100);
    wire [7:0] d10  = (result / 10) % 8'd10;
    wire [7:0] d1   = (result % 8'd10);

    // The 5-byte message: "DDD\r\n", selected by idx.
    reg  [2:0] idx;
    reg  [7:0] tx_byte;
    always @(*) begin
        case (idx)
            3'd0:    tx_byte = 8'h30 + d100[3:0]; // '0' + hundreds
            3'd1:    tx_byte = 8'h30 + d10[3:0];  // '0' + tens
            3'd2:    tx_byte = 8'h30 + d1[3:0];   // '0' + ones
            3'd3:    tx_byte = 8'h0D;             // CR
            default: tx_byte = 8'h0A;             // LF (idx 4)
        endcase
    end

    // Message-sender FSM: hands each byte to uart_tx and waits for it to finish.
    wire uart_busy;
    reg  tx_start;
    localparam S_IDLE = 2'd0, S_REQ = 2'd1, S_BUSY = 2'd2, S_DONE = 2'd3;
    reg [1:0] mstate;

    always @(posedge clk) begin
        if (reset) begin
            mstate   <= S_IDLE;
            idx      <= 3'd0;
            tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0; // default: one-cycle pulse only
            case (mstate)
                S_IDLE:  if (send_msg && done_s2) begin
                             idx    <= 3'd0;
                             mstate <= S_REQ;
                         end
                S_REQ:   if (!uart_busy) begin
                             tx_start <= 1'b1;     // kick off this byte
                             mstate   <= S_BUSY;
                         end
                S_BUSY:  if (uart_busy) mstate <= S_DONE; // byte started
                S_DONE:  if (!uart_busy) begin            // byte finished
                             if (idx == 3'd4) mstate <= S_IDLE;
                             else begin
                                 idx    <= idx + 3'd1;
                                 mstate <= S_REQ;
                             end
                         end
            endcase
        end
    end

    uart_tx my_uart (
        .clk(clk),                 // 27 MHz -> matches BAUD_LIMIT=234
        .reset(reset),
        .data_in(tx_byte),
        .tx_start(tx_start),
        .tx_out(uart_tx_out),
        .tx_busy(uart_busy)
    );

    // ---- LED display (active-low) ----
    wire [5:0] led_pattern = done ? {1'b1, result[4:0]} : 6'b000000;
    assign led = ~led_pattern;

endmodule
