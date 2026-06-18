//force the compiler to throw a hard error for a connection that is wrong
`default_nettype none
//set the time scale for the simulation
`timescale 1ns/1ns

// UART receiver, 8N1. Samples each bit at its midpoint.
// Emits rx_byte with a 1-cycle rx_valid pulse when a byte completes.
// (Adapted from the cnn_chip uart_rx; active-HIGH reset to match this project.)
module uart_rx #(
    parameter CLK_FREQ  = 27000000,
    parameter BAUD_RATE = 115200
) (
    input  wire       clk,
    input  wire       reset,     // return to waiting state
    input  wire       rx_in,     // copper wire coming from the PC
    output reg  [7:0] rx_byte, // 8 bits of data from the PC
    output reg        rx_valid   //sits at 0, pulses when receiver assembles 8 bits from rx_in, fr i clock cycle,dma grabs that data
);
    localparam integer BIT_TICK  = CLK_FREQ / BAUD_RATE; // 234 @ 27 MHz/115200
    localparam integer HALF_TICK = BIT_TICK / 2;

    localparam IDLE = 2'b00, START = 2'b01, DATA = 2'b10, STOP = 2'b11;

    reg [1:0]  state;
    reg [15:0] tick; //sfa estandard size, so timer soesnt overflow if baud rate is slower
    reg [2:0]  bit_index;
    reg [7:0]  shift_reg;

    always @(posedge clk) begin
        if (reset) begin
            state     <= IDLE;
            tick      <= 0;
            bit_index <= 0;
            shift_reg <= 0;
            rx_byte   <= 0;
            rx_valid  <= 0;
        end else begin
            rx_valid <= 1'b0; // default; pulse for one cycle in STOP

            case (state)
                IDLE: begin
                    tick <= 0;
                    if (rx_in == 1'b0) state <= START; // start bit (line goes low)
                end

                START: begin
                    // wait half a bit and re-check we're still in the start bit
                    if (tick == HALF_TICK) begin
                        if (rx_in == 1'b0) begin
                            tick      <= 0;
                            bit_index <= 0;
                            state     <= DATA;
                        end else begin
                            state <= IDLE; // glitch, not a real start
                        end
                    end else tick <= tick + 1'b1;
                end

                DATA: begin
                    // sample one full bit period after the mid-start point
                    if (tick == BIT_TICK - 1) begin
                        tick <= 0;
                        shift_reg[bit_index] <= rx_in; // LSB first
                        if (bit_index == 3'd7) state <= STOP;
                        else bit_index <= bit_index + 1'b1;
                    end else tick <= tick + 1'b1;
                end

                STOP: begin
                    if (tick == BIT_TICK - 1) begin
                        state    <= IDLE;
                        rx_byte  <= shift_reg;
                        rx_valid <= 1'b1;
                    end else tick <= tick + 1'b1;
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule