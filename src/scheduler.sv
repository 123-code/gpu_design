`default_nettype none
`timescale 1ns/1ns

module scheduler #(
    parameter THREADS_PER_BLOCK = 4 
) (
    input wire clk,//clock inputv
    input wire reset,//reset signal
    input wire start,//signal from the dispatcher to begin execution
    input wire decoded_ret,//comes from the instruction decoder,turns on on RET instruction, means the program must halt if this is high, we no longer fetch, we go to DONE
    input wire [1:0] lsu_state [THREADS_PER_BLOCK-1:0],//signals from the lsu to indicate its state
    output reg [2:0] core_state,//register holding state
    output reg done 
);
//instructions or states in which the scheduler finds itself
//starts at idle, waiting for a sognal to run, once the dispatcher loads the image , the shceduler transitions to fetch
    localparam IDLE = 3'b000, FETCH = 3'b001, DECODE = 3'b010, 
               REQUEST = 3'b011, WAIT = 3'b100, EXECUTE = 3'b101, 
               UPDATE = 3'b110, DONE = 3'b111;

    reg any_lsu_waiting;

    always @(posedge clk) begin //every time the clock ticks,the sceduler checks its state
        if (reset) begin//reset , core state goes to IDLE
            core_state <= IDLE;
            done <= 0;
        end else begin
            case (core_state)//acts as a switchboard, checking the state of core_state register
            IDLE: begin//once the start signal comes in from dispatcher, we move on to FETCH
                if (start) core_state <= FETCH; 
            end
            FETCH: begin //fetching the next instruction
                core_state <= DECODE;
            end
            DECODE: begin//tanslated the instruction
                core_state <= REQUEST; 
            end
            REQUEST: begin 
                core_state <= WAIT;    
            end
            WAIT: begin //checking if the threads are busy, checks if threads are reading, writing to RAM
                any_lsu_waiting = 1'b0;
                for (integer i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin
                    if (lsu_state[i] == 2'b01 || lsu_state[i] == 2'b10) begin
                        any_lsu_waiting = 1'b1;
                    end
                end
                if (!any_lsu_waiting) core_state <= EXECUTE; 
            end
            EXECUTE: begin//performs operations, moves to update, operatins must be done in a single clock cycle
                core_state <= UPDATE;  
            end
            UPDATE: begin // depending on decoded_ret, if high, we're done, if low, we fetch another instrcution
                if (decoded_ret) begin 
                    core_state <= DONE;
                end else begin 
                    core_state <= FETCH;
                end
            end
            DONE: begin 
            end
            endcase
            done <= (core_state == DONE);
        end
    end
endmodule
//q. how are we handling clock cycles here, if the threads run EXECUTE for exactly one cycle, ho does the MAC array do this?