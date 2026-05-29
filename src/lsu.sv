`default_nettype none
`timescale 1ns/1ns

module lsu (
    input wire clk,
    input wire reset,
    input wire enable, 
    input wire [2:0] core_state,         // Listens to the Scheduler's metronome

    // Control Pins (From Decoder)
    input wire decoded_mem_read,         // 1 = LDR instruction
    input wire decoded_mem_write,        // 1 = STR instruction

    // Data Pins (From Registers)
    input wire [7:0] rs,                 // Memory Address
    input wire [7:0] rt,                 // Data to save (for STR)

    // Highway to Arbiter/FIFO
    output reg mem_valid,                // "I have a request!"
    output reg [7:0] mem_addr,
    output reg [7:0] mem_write_data,
    input wire mem_ready,                // "Request complete!"
    input wire [7:0] mem_read_data,      // Payload from RAM

    // Output back to Thread
    output reg [1:0] lsu_state,          // 00=IDLE, 01=REQ, 10=WAIT, 11=DONE
    output reg [7:0] lsu_out             // Hand data back to Registers
);

    always @(posedge clk) begin
        if (reset) begin
            lsu_state <= 2'b00; // IDLE
            mem_valid <= 0;
            lsu_out <= 0;
        end else if (enable) begin
            
            // If the Decoder flags this as a Memory Read (LDR)
            if (decoded_mem_read) begin 
                case (lsu_state)
                    2'b00: begin // IDLE
                        if (core_state == 3'b011) lsu_state <= 2'b01; // Wake up on REQUEST phase
                    end
                    2'b01: begin // REQUESTING
                        mem_valid <= 1;        // Raise the flag to the Arbiter
                        mem_addr <= rs;        // Put address on the wire
                        lsu_state <= 2'b10;    // Move to WAITING
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