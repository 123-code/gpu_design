`default_nettype none
`timescale 1ns/1ns

// DMA controller: streams a fixed-size payload from the UART receiver into
// main memory, then hands memory to the GPU and triggers it to run.
//
// Flow:
//   S_LOAD : own the memory write port. Each rx_valid pulse stores one byte at
//            the current write pointer and advances it. After PAYLOAD_BYTES,
//            release the port, pulse gpu_start, and move to S_RUN.
//   S_RUN  : the GPU owns memory (reads only). Wait for gpu_done, then return
//            to S_LOAD for the next payload (pointer reset to 0).
//
// Payload convention (drops straight onto the 3x3 MAC): addr 0..8 = 9 pixels,
// addr 9..17 = 9 signed weights. Bump PAYLOAD_BYTES for larger frames.
module dma_controller #(
    parameter ADDR_BITS     = 13,
    parameter PAYLOAD_BYTES = 18
) (
    input  wire                 clk,
    input  wire                 reset,         // active-high

    // ---- from the UART receiver (uart_rx.sv) ----
    input  wire [7:0]           rx_byte,
    input  wire                 rx_valid,      // 1-cycle pulse per received byte

    // ---- GPU handshake ----
    input  wire                 gpu_done,      // GPU finished the previous payload
    output reg                  gpu_start,     // 1-cycle "payload ready, go" pulse

    // ---- main_memory write port (DMA drives it while loading) ----
    output reg                  mem_we,
    output reg  [ADDR_BITS-1:0] mem_waddr,
    output reg  [7:0]           mem_wdata,

    // ---- status: high while the DMA owns the write port ----
    output reg                  loading
);
    localparam S_LOAD = 1'b0,
               S_RUN  = 1'b1;

    reg                  state;
    reg [ADDR_BITS-1:0]  wptr;          // the memory write pointer
    reg                  gpu_done_d;    // for rising-edge detection of gpu_done

    always @(posedge clk) begin
        if (reset) begin
            state     <= S_LOAD;
            wptr      <= '0;
            mem_we    <= 1'b0;
            mem_waddr <= '0;
            mem_wdata <= 8'd0;
            gpu_start <= 1'b0;
            loading   <= 1'b1;
            gpu_done_d <= 1'b0;
        end else begin
            // Registered memory controls + the start pulse default to inactive;
            // they assert for exactly one cycle when something happens.
            mem_we    <= 1'b0;
            gpu_start <= 1'b0;
            gpu_done_d <= gpu_done;

            case (state)
                // ============================================================
                // LOADING: the DMA owns the write port and the pointer.
                // ============================================================
                S_LOAD: begin
                    loading <= 1'b1;

                    if (rx_valid) begin
                        // Commit THIS byte at the current write pointer.
                        mem_we    <= 1'b1;
                        mem_waddr <= wptr;
                        mem_wdata <= rx_byte;

                        if (wptr == PAYLOAD_BYTES - 1) begin
                            // Last byte of the payload just landed.
                            wptr      <= '0;        // rewind for the next frame
                            gpu_start <= 1'b1;       // wake the GPU
                            loading   <= 1'b0;       // release the write port
                            state     <= S_RUN;
                        end else begin
                            wptr <= wptr + 1'b1;     // advance to the next slot
                        end
                    end
                end

                // ============================================================
                // RUNNING: GPU reads the loaded data; DMA is idle.
                // ============================================================
                S_RUN: begin
                    loading <= 1'b0;
                    // Re-arm on a FRESH completion (rising edge of gpu_done), not
                    // its level. After a run, gpu_done stays high until the next
                    // run resets the GPU; using the level would bounce us straight
                    // back to S_LOAD on the next run's first cycle and block that
                    // run's memory writes (stale-result bug).
                    if (gpu_done && !gpu_done_d) state <= S_LOAD;
                end

                default: state <= S_LOAD;
            endcase
        end
    end
endmodule
