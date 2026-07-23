`default_nettype none
`timescale 1ns/1ns
module tb;
    localparam PROG_WORDS = 14;          
    localparam DATA_BYTES = 0;
    localparam BIT_CYCLES = 16;          

    reg  clk = 0;
    reg  uart_line = 1'b1;               
    wire uart_tx;                        
    wire [5:0] led;

    top #(
        .PAYLOAD_BYTES(DATA_BYTES),
        .CLK_FREQ(BIT_CYCLES),
        .BAUD_RATE(1)
    ) dut (
        .clk(clk),
        .uart_rx_in(uart_line),
        .uart_tx_out(uart_tx),
        .led(led)
    );

    always #5 clk = ~clk;

    reg [15:0] prog [0:PROG_WORDS-1];

    task uart_send(input [7:0] b);
        integer k;
        begin
            uart_line = 1'b0;                         
            repeat (BIT_CYCLES) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_line = b[k];                     
                repeat (BIT_CYCLES) @(posedge clk);
            end
            uart_line = 1'b1;                         
            repeat (BIT_CYCLES) @(posedge clk);
        end
    endtask

    task uart_recv(output [7:0] b);
        integer k;
        begin
            @(negedge uart_tx);                                  
            repeat (BIT_CYCLES + BIT_CYCLES/2) @(posedge clk);   
            for (k = 0; k < 8; k = k + 1) begin
                b[k] = uart_tx;
                repeat (BIT_CYCLES) @(posedge clk);
            end
        end
    endtask

    reg [7:0] r0, r1;
    integer i;
    initial begin
        $readmemh("software/program.hex", prog);
        repeat (64) @(posedge clk);

        uart_send(PROG_WORDS % 256); uart_send(PROG_WORDS / 256);
        uart_send(DATA_BYTES % 256); uart_send(DATA_BYTES / 256);

        for (i = 0; i < PROG_WORDS; i = i + 1) begin
            uart_send(prog[i][7:0]);
            uart_send(prog[i][15:8]);
        end

        uart_recv(r0); uart_recv(r1); 
        $display("reply bytes: %02x %02x", r0, r1);
        $finish;
    end
endmodule
