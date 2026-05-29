`default_nettype none
`timescale 1ns/1ns

module scheduler #(
    parameter THREADS_PER_BLOCK = 4 
) (
    input wire clk,
    input wire reset,
    input wire start,
    input wire decoded_ret,
    input wire [1:0] lsu_state [THREADS_PER_BLOCK-1:0],
    output reg [2:0] core_state,
    output reg done
);

    localparam IDLE = 3'b000, FETCH = 3'b001, DECODE = 3'b010, 
               REQUEST = 3'b011, WAIT = 3'b100, EXECUTE = 3'b101, 
               UPDATE = 3'b110, DONE = 3'b111;

    reg any_lsu_waiting;

    always @(posedge clk) begin 
        if (reset) begin
            core_state <= IDLE;
            done <= 0;
        end else begin
            case (core_state)
            IDLE: begin
                if (start) core_state <= FETCH; 
            end
            FETCH: begin 
                core_state <= DECODE;
            end
            DECODE: begin
                core_state <= REQUEST; 
            end
            REQUEST: begin 
                core_state <= WAIT;    
            end
            WAIT: begin
                any_lsu_waiting = 1'b0;
                for (integer i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin
                    if (lsu_state[i] == 2'b01 || lsu_state[i] == 2'b10) begin
                        any_lsu_waiting = 1'b1;
                    end
                end
                if (!any_lsu_waiting) core_state <= EXECUTE; 
            end
            EXECUTE: begin
                core_state <= UPDATE;  
            end
            UPDATE: begin 
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