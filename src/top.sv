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
    // MNIST FC-classifier payload (mnist_fc.asm): the host streams the
    // interleaved (feature, weight) sweep -- 10 digits x 169 inputs x 2 bytes =
    // 3380 bytes -- which the GPU base-sweeps through the FC-MAC coprocessor.
    parameter PAYLOAD_BYTES = 3380,
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
    wire [11:0] mem_raddr;            // driven by the GPU's LSU arbiter (4096-byte space)
    wire [7:0]  mem_rdata;
    wire        done;                 // GPU finished a run
    wire [7:0]  result;

    data_pipeline #(
        .ADDR_BITS(12),
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
    wire       emit_valid;
    wire [7:0] emit_data;
    reg        emit_ready;

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
        .mem_rdata(mem_rdata),
        .emit_valid(emit_valid),
        .emit_data(emit_data),
        .emit_ready(emit_ready)
    );

    // ========================================================================
    // Memory-mapped emit -> UART TX (one raw byte per STR to offset 63).
    // The handshake (emit_valid held until emit_ready) throttles the GPU to the
    // UART byte rate, so no output is dropped.
    // ========================================================================
    wire uart_busy;
    reg  tx_start;
    localparam E_IDLE = 2'd0, E_SEND = 2'd1, E_WAIT = 2'd2;
    reg [1:0] estate;
    always @(posedge clk) begin
        if (sys_reset) begin
            estate <= E_IDLE; tx_start <= 1'b0; emit_ready <= 1'b0;
        end else begin
            tx_start <= 1'b0; emit_ready <= 1'b0;
            case (estate)
                E_IDLE: if (emit_valid && !uart_busy) begin
                            tx_start <= 1'b1;            // launch emit_data
                            estate   <= E_SEND;
                        end
                E_SEND: if (uart_busy) estate <= E_WAIT; // byte started
                E_WAIT: if (!uart_busy) begin            // byte fully sent
                            emit_ready <= 1'b1;          // ack the GPU's STR
                            estate     <= E_IDLE;
                        end
            endcase
        end
    end

    uart_tx #(.BAUD_LIMIT(CLK_FREQ / BAUD_RATE)) u_tx (
        .clk(clk), .reset(sys_reset),
        .data_in(emit_data), .tx_start(tx_start),
        .tx_out(uart_tx_out), .tx_busy(uart_busy)
    );

    // ---- LEDs: loading status + done + low nibble of the result ----
    assign led = ~{loading, done, result[3:0]};

endmodule
