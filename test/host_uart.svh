// Shared host side of the UART link, `include'd inside a testbench module.
//
// The including module must declare, before the include:
//     reg  clk;  reg uart_line;  wire uart_tx;
//     localparam BIT_CYCLES = <CLK_FREQ/BAUD_RATE of the dut>;
//
// send_frame streams one launch exactly as software/send_kernel.py does:
//     header : instr_size | gridDim<<9 (LE16), data_size (LE16)
//     program: each 16-bit word low byte, high byte
//     data   : raw bytes (broadcast into both cores' memory)
// The DMA drops the final payload byte (documented race), so send_frame
// appends one pad byte itself; callers pass only the real data.

task automatic uart_send(input [7:0] b);
    integer k;
    begin
        uart_line = 1'b0;                              // start bit
        repeat (BIT_CYCLES) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin
            uart_line = b[k];                          // data, LSB first
            repeat (BIT_CYCLES) @(posedge clk);
        end
        uart_line = 1'b1;                              // stop bit
        repeat (BIT_CYCLES) @(posedge clk);
    end
endtask

task automatic uart_recv(output [7:0] b);
    integer k;
    begin
        @(negedge uart_tx);                                  // start bit
        repeat (BIT_CYCLES + BIT_CYCLES/2) @(posedge clk);   // centre of bit 0
        for (k = 0; k < 8; k = k + 1) begin
            b[k] = uart_tx;
            repeat (BIT_CYCLES) @(posedge clk);
        end
    end
endtask

// Program and data staging buffers (fill, then call send_frame)
reg [15:0] host_prog [0:255];
reg [7:0]  host_data [0:8191];

task automatic send_frame(input integer nwords, input integer nbytes, input integer grid);
    send_frame_ex(nwords, nbytes, grid, 0);
endtask

// flags bit 0: the payload goes to global memory (SDRAM), header data_size
//               bit 15, instead of the cores' data memories
// flags bit 1: cluster launch (data_size bit 14)
task automatic send_frame_ex(input integer nwords, input integer nbytes, input integer grid,
                             input integer flags);
    integer i;
    reg [15:0] w0, w1;
    begin
        w0 = nwords[15:0] | (grid[15:0] << 9);
        w1 = (nbytes + 1) | (flags[0] ? 16'h8000 : 16'h0000) | (flags[1] ? 16'h4000 : 16'h0000);
        uart_send(w0[7:0]); uart_send(w0[15:8]);
        uart_send(w1[7:0]); uart_send(w1[15:8]);
        for (i = 0; i < nwords; i = i + 1) begin
            uart_send(host_prog[i][7:0]);
            uart_send(host_prog[i][15:8]);
        end
        for (i = 0; i < nbytes; i = i + 1)
            uart_send(host_data[i]);
        uart_send(8'h00);                              // pad: absorbs the drop
    end
endtask

// Count the words of a $readmemh'd program (stops at the first X word)
function automatic integer prog_len(input integer max);
    integer i;
    begin
        prog_len = max;
        for (i = 0; i < max; i = i + 1)
            if (^host_prog[i] === 1'bx && prog_len == max) prog_len = i;
    end
endfunction
