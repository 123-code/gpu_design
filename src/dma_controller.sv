`default_nettype none
`timescale 1ns/1ns

//stack bytres neatly into sram 

module dma_controller #(
    //13 wires for the addresses
    parameter ADDR_BITS     = 13
) (
    input  wire                 clk,
    input  wire                 reset,    

    // ---- from the UART receiver (uart_rx.sv) ----
    input  wire [7:0]           rx_byte,
    input  wire                 rx_valid,      // 1-cycle pulse per received byte, when it spikes, the dma drives ports to put the byte in sram

    // ---- GPU handshake ----
    input  wire                 gpu_done,      // dma does not listen to uart, until the gpu moves this wire to 1
    output reg                  gpu_start,     //spikes to 1 once DMA writes the fnall payload byte

    // _memory write ports the dma drives
    output reg                  mem_we,   //spikes to one, for one clock cycle, sram saves memwdata into memwaddr
    output reg  [ADDR_BITS-1:0] mem_waddr, //write address, defining location in sram
    output reg  [7:0]           mem_wdata, //8 bit wire carrying the pixel 

    // ---- instruction memory write ports ----
    output reg                  instr_we,
    output reg  [7:0]           instr_waddr,
    output reg  [15:0]          instr_wdata,

    // ---- status: high while the DMA owns the write port ----
    output reg                  loading
);
//we have 4 headers with metadata on the incoming data and incoming instruction. high and low bytes
//header cna be looked as the metadata used by the dma to order incoming data
    localparam S_HEADER_INSTR_L = 3'd0,
               S_HEADER_INSTR_H = 3'd1,
               S_HEADER_DATA_L  = 3'd2,
               S_HEADER_DATA_H  = 3'd3,
               S_LOAD_INSTR     = 3'd4,
               S_LOAD_DATA      = 3'd5,
               S_RUN            = 3'd6;

    reg [2:0]            state;
    reg [ADDR_BITS-1:0]  wptr;          // the memory write pointer
    reg                  gpu_done_d;    // for rising-edge detection of gpu_done
    
    reg [15:0]           instr_size;    // How many bytes of assembly code
    reg [15:0]           data_size;     // How many bytes of data
    
    reg [15:0]           instr_wdata_reg; // Holds the first half of a 16-bit instruction
    reg                  byte_toggle;     // 0 = low byte, 1 = high byte

    always @(posedge clk) begin
    //force things to their default states to avoid randomness pulling in erroneous states
        if (reset) begin
            state     <= S_HEADER_INSTR_L;
            wptr      <= '0;
            gpu_start <= 1'b0;
            loading   <= 1'b0;
            mem_we    <= 1'b0;
            instr_we  <= 1'b0;
            instr_waddr <= 8'd0;
            byte_toggle <= 1'b0;
            gpu_done_d <= 1'b0;
        end else begin
            gpu_done_d <= gpu_done;
            gpu_start  <= 1'b0;          // 1-cycle pulse by default
            mem_we     <= 1'b0;
            instr_we   <= 1'b0;

            case (state)
                // ============================================================
                // HEADER: Receive the 4-byte size header
                // ============================================================
                S_HEADER_INSTR_L: begin
                    loading <= 1'b1;
                    if (rx_valid) begin
                        instr_size[7:0] <= rx_byte;
                        state <= S_HEADER_INSTR_H;
                    end
                end

                S_HEADER_INSTR_H: begin
                    loading <= 1'b1;
                    if (rx_valid) begin
                        instr_size[15:8] <= rx_byte;
                        state <= S_HEADER_DATA_L;
                    end
                end

                S_HEADER_DATA_L: begin
                    loading <= 1'b1;
                    if (rx_valid) begin
                        data_size[7:0] <= rx_byte;
                        state <= S_HEADER_DATA_H;
                    end
                end

                S_HEADER_DATA_H: begin
                    loading <= 1'b1;
                    if (rx_valid) begin
                        data_size[15:8] <= rx_byte;
                        wptr <= '0;
                        instr_waddr <= 8'd0;
                        byte_toggle <= 1'b0;
                        if (instr_size == 0) begin
                            state <= S_LOAD_DATA;
                        end else begin
                            state <= S_LOAD_INSTR;
                        end
                    end
                end

                // ============================================================
                // LOAD INSTR: Piece together 8-bit chunks into 16-bit instructions
                // ============================================================
                S_LOAD_INSTR: begin
                    loading <= 1'b1;
                    if (rx_valid) begin
                        if (byte_toggle == 1'b0) begin
                            // Catch the first 8 bits
                            instr_wdata_reg[7:0] <= rx_byte;
                            byte_toggle <= 1'b1;
                            
                            if (wptr == instr_size - 1) begin
                                wptr <= '0;
                                state <= (data_size == 0) ? S_RUN : S_LOAD_DATA;
                                if (data_size == 0) gpu_start <= 1'b1;
                            end else begin
                                wptr <= wptr + 1'b1;
                            end
                        end else begin
                            // Catch the next 8 bits, assemble into 16, and write!
                            instr_wdata <= {rx_byte, instr_wdata_reg[7:0]};
                            instr_we <= 1'b1;
                            byte_toggle <= 1'b0;
                            
                            if (wptr == instr_size - 1) begin
                                wptr <= '0;
                                state <= (data_size == 0) ? S_RUN : S_LOAD_DATA;
                                if (data_size == 0) gpu_start <= 1'b1;
                            end else begin
                                wptr <= wptr + 1'b1;
                                instr_waddr <= instr_waddr + 1'b1; // Advance the memory address
                            end
                        end
                    end
                end

                // ============================================================
                // LOAD DATA: Write incoming payload sequentially into SRAM
                // ============================================================
                S_LOAD_DATA: begin
                    loading <= 1'b1;
                    if (data_size == 0) begin
                        gpu_start <= 1'b1;
                        loading <= 1'b0;
                        state <= S_RUN;
                    end else if (rx_valid) begin
                        mem_we    <= 1'b1;
                        mem_waddr <= wptr;
                        mem_wdata <= rx_byte;

                        if (wptr == data_size[ADDR_BITS-1:0] - 1) begin
                            // Last byte of the payload just landed.
                            wptr      <= '0;        // rewind for the next frame
                            gpu_start <= 1'b1;       // wake the GPU
                            loading   <= 1'b0;       // release the write port
                            state     <= S_RUN;
                        end else begin
                            wptr <= wptr + 1'b1;
                        end
                    end
                end

                // ============================================================
                // RUNNING: GPU reads the loaded data; DMA is idle.
                // ============================================================
                S_RUN: begin
                    loading <= 1'b0;
                    if (gpu_done && !gpu_done_d) state <= S_HEADER_INSTR_L;
                end

                default: state <= S_HEADER_INSTR_L;
            endcase
        end
    end
endmodule
