`default_nettype none
`timescale 1ns/1ns

module uart_tx #(
    parameter BAUD_LIMIT = 234   // 27 MHz / 115200 baud; override (small) in sim
) (
    input wire clk,           // The 27 MHz system clock
    input wire reset,

    input wire [7:0] data_in, // The 8-bit answer coming out of the FIFO
    input wire tx_start,      // A pulse telling us to grab the data and start sending

    output reg tx_out,        // The single physical copper wire to the laptop
    output reg tx_busy        // Tells the FIFO "Hold on, I'm shifting!"
);

    
    // State Machine
    localparam IDLE = 2'b00, START_BIT = 2'b01, DATA_BITS = 2'b10, STOP_BIT = 2'b11;
    reg [1:0] state;
    
    reg [7:0] clock_count;    // Counts to 234
    reg [2:0] bit_index;      // Counts which of the 8 data bits we are sending
    reg [7:0] shift_register; // Holds the matrix answer while we send it

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            tx_out <= 1;      // UART idle state is always HIGH (1)
            tx_busy <= 0;
            clock_count <= 0;
            bit_index <= 0;
            shift_register <= 0;
        end else begin
            case (state)
                IDLE: begin
                    tx_out <= 1;
                    clock_count <= 0;
                    bit_index <= 0;
                    
                    // When told to start, lock the data into the shift register
                    if (tx_start) begin
                        shift_register <= data_in;
                        tx_busy <= 1;
                        state <= START_BIT;
                    end else begin
                        tx_busy <= 0;
                    end
                end
                
                START_BIT: begin
                    tx_out <= 0; // The Start Bit is always LOW (0)
                    if (clock_count < BAUD_LIMIT - 1) begin
                        clock_count <= clock_count + 1;
                    end else begin
                        clock_count <= 0;
                        state <= DATA_BITS;
                    end
                end
                
                DATA_BITS: begin
                    // Output the current bit from the shift register
                    tx_out <= shift_register[bit_index];
                    
                    if (clock_count < BAUD_LIMIT - 1) begin
                        clock_count <= clock_count + 1;
                    end else begin
                        clock_count <= 0;
                        if (bit_index < 7) begin
                            bit_index <= bit_index + 1; // Move to the next bit
                        end else begin
                            state <= STOP_BIT;          // All 8 bits sent!
                        end
                    end
                end
                
                STOP_BIT: begin
                    tx_out <= 1; // The Stop Bit is always HIGH (1)
                    if (clock_count < BAUD_LIMIT - 1) begin
                        clock_count <= clock_count + 1;
                    end else begin
                        clock_count <= 0;
                        state <= IDLE; // Done! Go back and wait for next byte.
                    end
                end
            endcase
        end
    end

endmodule