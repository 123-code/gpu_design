`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Tang Nano 20K top-level for tiny-gpu, with bidirectional UART.
//
//   Laptop -> FPGA : type two decimal numbers + Enter, e.g. "7 6\r".
//                    They patch the kernel's operands (R4 = A, R2 = B), the GPU
//                    re-runs, and computes A * B by repeated addition.
//   FPGA -> Laptop : the result is sent back as ASCII decimal + CRLF ("042\r\n").
//
//   Also: LED5 + LED3..0 show the latest result (active-LOW).
//
// Operands are 6-bit (0..63) because they land in 6-bit MOV immediates; the
// result is 8-bit so keep the product <= 255. UART is 115200 8N1 (TX=69, RX=70).
// ============================================================================
module top (
    input  wire       clk,          // 27 MHz crystal       (PIN 4)
    input  wire       uart_rx_in,    // UART RX from laptop  (PIN 70)
    output wire       uart_tx_out,   // UART TX to laptop    (PIN 69)
    output wire [5:0] led            // 6 onboard LEDs        (PIN 15..20)
);
    // ---- divide 27 MHz -> ~13 kHz GPU clock ----
    reg [10:0] div = 11'd0;
    always @(posedge clk) div <= div + 1'b1;
    wire gpu_clk = div[10];

    // ========================================================================
    // Fast (27 MHz) domain: power-on reset for the UART + parser logic.
    // (Separate from the GPU reset, which pulses on every new run.)
    // ========================================================================
    reg  [3:0] por_fast = 4'd0;
    wire reset_fast = ~(&por_fast);
    always @(posedge clk) if (reset_fast) por_fast <= por_fast + 1'b1;

    // ---- UART receiver ----
    wire [7:0] rx_byte;
    wire       rx_valid;
    uart_rx rx (
        .clk(clk), .reset(reset_fast),
        .rx_in(uart_rx_in),
        .rx_byte(rx_byte), .rx_valid(rx_valid)
    );

    // ---- ASCII decimal parser: "<A><sep><B><CR|LF>" ----
    wire is_digit = (rx_byte >= 8'h30) && (rx_byte <= 8'h39);
    wire [3:0] digit = rx_byte[3:0];                       // '0'..'9' low nibble
    wire is_sep = (rx_byte == 8'h20) || (rx_byte == 8'h2C); // space or comma
    wire is_end = (rx_byte == 8'h0D) || (rx_byte == 8'h0A); // CR or LF

    localparam P_A = 1'b0, P_B = 1'b1;
    reg        pstate;
    reg  [7:0] num_a, num_b;
    reg  [5:0] ext_a = 6'd5, ext_b = 6'd3; // defaults -> 5 * 3 at power-up
    reg        run_toggle = 1'b0;          // flips when a new pair is ready

    always @(posedge clk) begin
        if (reset_fast) begin
            pstate <= P_A; num_a <= 8'd0; num_b <= 8'd0;
            ext_a <= 6'd5; ext_b <= 6'd3; run_toggle <= 1'b0;
        end else if (rx_valid) begin
            if (is_digit) begin
                if (pstate == P_A) num_a <= num_a * 8'd10 + digit;
                else               num_b <= num_b * 8'd10 + digit;
            end else if (is_sep) begin
                if (pstate == P_A) begin pstate <= P_B; num_b <= 8'd0; end
            end else if (is_end) begin
                if (pstate == P_B) begin               // got both numbers
                    ext_a      <= num_a[5:0];
                    ext_b      <= num_b[5:0];
                    run_toggle <= ~run_toggle;         // request a re-run
                end
                pstate <= P_A; num_a <= 8'd0; num_b <= 8'd0;
            end
        end
    end

    // ========================================================================
    // GPU (slow ~13 kHz domain). Re-runs whenever new operands arrive.
    // ========================================================================
    // Cross the run request (toggle) into the slow domain and edge-detect it.
    reg [2:0] tog_sync = 3'd0;
    always @(posedge gpu_clk) tog_sync <= {tog_sync[1:0], run_toggle};
    wire new_run = tog_sync[2] ^ tog_sync[1];

    // Power-on reset that ALSO restarts on each new run (reuse the POR counter).
    reg  [3:0] por = 4'd0;
    wire por_done = &por;
    always @(posedge gpu_clk) begin
        if (new_run)          por <= 4'd0;        // restart the GPU
        else if (!por_done)   por <= por + 1'b1;
    end
    wire reset  = !por_done;
    wire enable = por_done;

    wire [7:0] result;
    wire       done;

    gpu uut (
        .clk(gpu_clk),
        .reset(reset),
        .enable(enable),
        .result(result),
        .done(done),
        .debug_core_state(),
        .debug_instruction(),
        .operand_a(ext_a),
        .operand_b(ext_b)
    );

    // ========================================================================
    // Reply: when the GPU finishes a run, transmit the result over UART.
    // ========================================================================
    // Synchronize 'done' into the fast domain and detect its rising edge.
    reg done_s1 = 0, done_s2 = 0, done_s3 = 0;
    always @(posedge clk) begin
        done_s1 <= done; done_s2 <= done_s1; done_s3 <= done_s2;
    end
    wire send_msg = done_s2 & ~done_s3; // one pulse per completed run

    // Latch the result for the duration of the transmission.
    reg [7:0] result_q = 8'd0;
    always @(posedge clk) if (send_msg) result_q <= result;

    // Decimal digits of the latched result (0..255).
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
            3'd3:    tx_byte = 8'h0D; // CR
            default: tx_byte = 8'h0A; // LF
        endcase
    end

    // Message-sender FSM: hand each byte to uart_tx, wait for it to finish.
    wire uart_busy;
    reg  tx_start;
    localparam S_IDLE = 2'd0, S_REQ = 2'd1, S_BUSY = 2'd2, S_DONE = 2'd3;
    reg [1:0] mstate;
    reg       pending; // a send was requested while busy

    always @(posedge clk) begin
        if (reset_fast) begin
            mstate <= S_IDLE; idx <= 3'd0; tx_start <= 1'b0; pending <= 1'b0;
        end else begin
            tx_start <= 1'b0;
            if (send_msg) pending <= 1'b1; // remember the request
            case (mstate)
                S_IDLE:  if (pending) begin
                             pending <= 1'b0; idx <= 3'd0; mstate <= S_REQ;
                         end
                S_REQ:   if (!uart_busy) begin tx_start <= 1'b1; mstate <= S_BUSY; end
                S_BUSY:  if (uart_busy) mstate <= S_DONE;
                S_DONE:  if (!uart_busy) begin
                             if (idx == 3'd4) mstate <= S_IDLE;
                             else begin idx <= idx + 3'd1; mstate <= S_REQ; end
                         end
            endcase
        end
    end

    uart_tx tx (
        .clk(clk), .reset(reset_fast),
        .data_in(tx_byte), .tx_start(tx_start),
        .tx_out(uart_tx_out), .tx_busy(uart_busy)
    );

    // ---- LED display (active-low): show the latest result when done ----
    wire [5:0] led_pattern = done ? {1'b1, result[4:0]} : 6'b000000;
    assign led = ~led_pattern;

endmodule
