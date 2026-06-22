`default_nettype none
`timescale 1ns/1ns

module lsu #(
    parameter ADDR_BITS = 13
) (//clock, reset and enable wires
    input wire clk,
    input wire reset,
    input wire enable,
    input wire thread_active,
    input wire warp_active, // NEW: Warp-level masking            // Is this thread awake?
    input wire [3:0] core_state,         // 4-bit pipeline phase from the scheduler

    // Control Pins (From Decoder) tells which operation to perform
    input wire decoded_mem_read,         // 1 = LDR load instruction
    input wire decoded_mem_write,        // 1 = STR store instruction
    input wire decoded_base_add,         // 1 = ADDB  read window (read base  += immediate)
    input wire decoded_wbase_add,        // 1 = WBASE slide read window forward (write base += immediate)
    input wire [7:0] decoded_immediate,  // amount to add to a base

    // Data Pins (From Registers)
    input wire [7:0] rs,                 // data that determines the address
    input wire [7:0] rt,                // //data target register

    // Highway to Arbiter/FIFO (reads)
    output reg mem_valid,                // LSU requests data"
    output reg [ADDR_BITS-1:0] mem_addr,//memory address to be read from the LSU
    output reg [7:0] mem_write_data,
    input wire mem_ready,                // "flag from memory controller indicating the data has been sent"
    input wire [7:0] mem_read_data,      // Payload from RAM

    // Write port back to main memory (STR to a non-MMIO address). 1-cycle pulse.
    output reg                  mem_we,//write enable, memory can overwrite whatever is at target address
    output reg [ADDR_BITS-1:0]  mem_waddr, //13 bit target address for writing 
    output reg [7:0]            mem_wdata,//data to be written

    // Memory-mapped emit (STR to offset 63 -> UART TX). Handshake throttles the
    // GPU to UART speed: emit_valid holds until emit_ready, stalling the scheduler.
    output reg       emit_valid,//LSU tries to send a byte to UART
    output reg [7:0] emit_data,//data to be sent to UART
    input  wire      emit_ready,//UART accepts the data

    // Output back to Thread
    output reg [1:0] lsu_state,          // broadcasts LSU state to scheduler
    output reg [7:0] lsu_out             // data goes to this register when read is finished
);

    localparam MMIO_TX = 8'd63;          // reserved offset -> UART TX register

    // Data-memory base pointers. LDR address = base + rs; STR address = wbase + rs.
    // Two independent pointers let a kernel READ one region (e.g. the image) and
    // WRITE another (e.g. the conv feature map) without reloading constants.
    // Both move in small ADDB/WBASE steps (forward only).
    reg [ADDR_BITS-1:0] base;    // read base  (ADDB)
    reg [ADDR_BITS-1:0] wbase;   // write base (WBASE)
    reg active_is_read;
    reg active_is_write;

    always @(posedge clk) begin
        if (reset) begin
            lsu_state <= 2'b00;
            lsu_out <= 0;
            base <= 0;
            wbase <= 0;
            
            emit_valid <= 0;
            emit_data <= 0;

            mem_valid <= 0;
            mem_addr <= '0;
            
            mem_we <= 0;
            mem_waddr <= '0;
            mem_wdata <= 0;
            
            active_is_read <= 0;
            active_is_write <= 0;
        end else if (enable) begin
            // Base pointers only update if THIS warp is active and in UPDATE state
            if (decoded_base_add && core_state == 4'b0111 && warp_active)
                base <= base + decoded_immediate;
            if (decoded_wbase_add && core_state == 4'b0111 && warp_active)
                wbase <= wbase + decoded_immediate;

            mem_we <= 1'b0;

            case (lsu_state)
                // ---- 00 IDLE: wake at REQUEST, capture read/write intent ----
                // Do NOT form the address yet: rs/rt are latched by the register
                // file AT REQUEST, so they only become valid next cycle. Issuing
                // here would use the previous instruction's operands (a load-use
                // hazard). Defer the actual issue to state 01.
                2'b00: if (core_state == 4'b0100 && thread_active && warp_active) begin
                    if (decoded_mem_read) begin
                        active_is_read  <= 1'b1;
                        active_is_write <= 1'b0;
                        lsu_state       <= 2'b01;
                    end else if (decoded_mem_write) begin
                        active_is_read  <= 1'b0;
                        active_is_write <= 1'b1;
                        lsu_state       <= 2'b01;
                    end
                end

                // ---- 01 ISSUE: rs/rt are valid now -> form the address/data ----
                2'b01: begin
                    if (active_is_read) begin
                        mem_valid <= 1'b1;
                        mem_addr  <= base + rs;
                        lsu_state <= 2'b10;
                    end else begin
                        if (rs == MMIO_TX) begin
                            emit_valid <= 1'b1;            // offset 63 -> UART TX
                            emit_data  <= rt;
                            lsu_state  <= 2'b10;
                        end else begin
                            mem_we    <= 1'b1;             // commit a BRAM write
                            mem_waddr <= wbase + rs;
                            mem_wdata <= rt;
                            lsu_state <= 2'b11;
                        end
                    end
                end

                // ---- 10 WAIT: read for mem_ready, emit for emit_ready ----
                2'b10: begin
                    if (active_is_read) begin
                        if (mem_ready) begin
                            mem_valid <= 1'b0;
                            lsu_out   <= mem_read_data;
                            lsu_state <= 2'b11;
                        end
                    end else begin
                        if (emit_ready) begin
                            emit_valid <= 1'b0;
                            lsu_state  <= 2'b11;
                        end
                    end
                end

                // ---- 11 DONE: hold until this warp's UPDATE, then re-arm ----
                2'b11: if (warp_active && core_state == 4'b0111) lsu_state <= 2'b00;
            endcase
        end
    end
endmodule