`default_nettype none
`timescale 1ns/1ns

module lsu #(
    parameter ADDR_BITS = 12
) (
    input wire clk,
    input wire reset,
    input wire enable,
    input wire [2:0] core_state,         // Listens to the Scheduler's metronome

    // Control Pins (From Decoder)
    input wire decoded_mem_read,         // 1 = LDR instruction
    input wire decoded_mem_write,        // 1 = STR instruction
    input wire decoded_base_add,         // 1 = ADDB  (read base  += immediate)
    input wire decoded_wbase_add,        // 1 = WBASE (write base += immediate)
    input wire [7:0] decoded_immediate,  // amount to add to a base

    // Data Pins (From Registers)
    input wire [7:0] rs,                 // Memory offset (within the window/page)
    input wire [7:0] rt,                 // Data to save (for STR)

    // Highway to Arbiter/FIFO (reads)
    output reg mem_valid,                // "I have a request!"
    output reg [ADDR_BITS-1:0] mem_addr,
    output reg [7:0] mem_write_data,
    input wire mem_ready,                // "Request complete!"
    input wire [7:0] mem_read_data,      // Payload from RAM

    // Write port back to main memory (STR to a non-MMIO address). 1-cycle pulse.
    output reg                  mem_we,
    output reg [ADDR_BITS-1:0]  mem_waddr,
    output reg [7:0]            mem_wdata,

    // Memory-mapped emit (STR to offset 63 -> UART TX). Handshake throttles the
    // GPU to UART speed: emit_valid holds until emit_ready, stalling the scheduler.
    output reg       emit_valid,
    output reg [7:0] emit_data,
    input  wire      emit_ready,

    // Output back to Thread
    output reg [1:0] lsu_state,          // 00=IDLE, 01=REQ, 10=WAIT, 11=DONE
    output reg [7:0] lsu_out             // Hand data back to Registers
);

    localparam MMIO_TX = 8'd63;          // reserved offset -> UART TX register

    // Data-memory base pointers. LDR address = base + rs; STR address = wbase + rs.
    // Two independent pointers let a kernel READ one region (e.g. the image) and
    // WRITE another (e.g. the conv feature map) without reloading constants.
    // Both move in small ADDB/WBASE steps (forward only).
    reg [ADDR_BITS-1:0] base;    // read base  (ADDB)
    reg [ADDR_BITS-1:0] wbase;   // write base (WBASE)

    always @(posedge clk) begin
        if (reset) begin
            lsu_state <= 2'b00; // IDLE
            mem_valid <= 0;
            lsu_out <= 0;
            base <= '0;
            wbase <= '0;
            emit_valid <= 0;
            emit_data <= 0;
            mem_we <= 0;
            mem_waddr <= '0;
            mem_wdata <= 0;
        end else if (enable) begin

            // ADDB / WBASE: advance the read / write base in the UPDATE phase.
            if (decoded_base_add  && core_state == 3'b110)
                base  <= base  + decoded_immediate;
            if (decoded_wbase_add && core_state == 3'b110)
                wbase <= wbase + decoded_immediate;

            // --- STR: store to main memory / memory-mapped emit ---
            mem_we <= 1'b0;                              // write strobe defaults low
            if (decoded_mem_write) begin
                case (lsu_state)
                    2'b00: if (core_state == 3'b011) lsu_state <= 2'b01; // wake on REQUEST
                    2'b01: begin // decode the target
                        if (rs == MMIO_TX) begin
                            emit_valid <= 1'b1;          // offset 63 -> UART TX
                            emit_data  <= rt;
                            lsu_state  <= 2'b10;         // wait for the byte to be accepted
                        end else begin
                            mem_we    <= 1'b1;           // commit a BRAM write next cycle
                            mem_waddr <= wbase + rs;     // write base + offset
                            mem_wdata <= rt;
                            lsu_state <= 2'b11;
                        end
                    end
                    2'b10: if (emit_ready) begin          // UART took the byte
                        emit_valid <= 1'b0;
                        lsu_state  <= 2'b11;
                    end
                    2'b11: if (core_state == 3'b110) lsu_state <= 2'b00;
                endcase
            end

            // If the Decoder flags this as a Memory Read (LDR)
            if (decoded_mem_read) begin
                case (lsu_state)
                    2'b00: begin // IDLE
                        if (core_state == 3'b011) lsu_state <= 2'b01; // Wake up on REQUEST phase
                    end
                    2'b01: begin // REQUESTING
                        mem_valid <= 1;                  // Raise the flag to the Arbiter
                        mem_addr <= base + rs;           // base + offset (full address)
                        lsu_state <= 2'b10;              // Move to WAITING
                    end
                    2'b10: begin // WAITING
                        if (mem_ready) begin   // Arbiter drops the payload!
                            mem_valid <= 0;    // Lower the flag
                            lsu_out <= mem_read_data; // Catch the data
                            lsu_state <= 2'b11; // Move to DONE
                        end
                    end
                    2'b11: begin // DONE
                        if (core_state == 3'b110) lsu_state <= 2'b00; // Go back to sleep after UPDATE
                    end
                endcase
            end
        end
    end
endmodule