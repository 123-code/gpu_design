`default_nettype none
`timescale 1ns/1ns

// Verifies the Host-to-Device path: bit-bang 793 UART frames into the pipeline
// and confirm every byte lands sequentially in SRAM, that gpu_start pulses after
// the last byte, and that loading deasserts.
//
// Uses a short bit period (BIT_CYCLES) for sim speed: the pipeline's uart_rx is
// instantiated with CLK_FREQ/BAUD_RATE giving the same BIT_TICK.
module tb;
    localparam ADDR_BITS  = 10;
    localparam PAYLOAD    = 793;
    localparam BIT_CYCLES = 16;        // must equal uart_rx BIT_TICK below

    reg clk = 0, reset = 1;
    reg uart_line = 1'b1;              // UART idle = high
    reg gpu_done = 1'b0;
    reg [ADDR_BITS-1:0] mem_raddr = 0;
    wire gpu_start, loading;
    wire [7:0] mem_rdata;

    // CLK_FREQ/BAUD_RATE = 16 -> BIT_TICK = 16 = BIT_CYCLES
    data_pipeline #(
        .ADDR_BITS(ADDR_BITS),
        .PAYLOAD_BYTES(PAYLOAD),
        .CLK_FREQ(16),
        .BAUD_RATE(1)
    ) dut (
        .clk(clk), .reset(reset),
        .uart_rx_in(uart_line),
        .gpu_done(gpu_done),
        .gpu_start(gpu_start),
        .loading(loading),
        .mem_raddr(mem_raddr),
        .mem_rdata(mem_rdata)
    );

    always #5 clk = ~clk;             // 100 MHz sim clock

    // Golden copy of what we sent.
    reg [7:0] sent [0:PAYLOAD-1];

    // Latch whether gpu_start was ever observed.
    reg start_seen = 1'b0;
    always @(posedge clk) if (gpu_start) start_seen <= 1'b1;

    // Drive one 8N1 UART frame onto the line, LSB first.
    task uart_send(input [7:0] b);
        integer k;
        begin
            uart_line = 1'b0;                                  // start bit
            repeat (BIT_CYCLES) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_line = b[k];                              // data, LSB first
                repeat (BIT_CYCLES) @(posedge clk);
            end
            uart_line = 1'b1;                                  // stop bit
            repeat (BIT_CYCLES) @(posedge clk);
        end
    endtask

    integer i, mismatches, mismatches2;
    reg phase1_start, phase1_released;
    initial begin
        // Reset
        repeat (4) @(posedge clk);
        reset = 0;
        repeat (4) @(posedge clk);

        // Stream the payload (deterministic pseudo-random pattern hits all values)
        for (i = 0; i < PAYLOAD; i = i + 1) begin
            sent[i] = (i * 131 + 7) & 8'hFF;
            uart_send(sent[i]);
        end

        // Let the last byte's write + gpu_start settle.
        repeat (8) @(posedge clk);

        // ---- Check 1: control handshake (after the full payload) ----
        phase1_start    = start_seen;   // gpu_start pulsed?
        phase1_released = !loading;      // write port released (in S_RUN)?
        $display("gpu_start seen = %0b (expected 1)", phase1_start);
        $display("loading now    = %0b (expected 0)", phase1_released ? 1'b0 : 1'b1);

        // ---- Check 2: every byte landed at the right address ----
        mismatches = 0;
        for (i = 0; i < PAYLOAD; i = i + 1) begin
            mem_raddr = i[ADDR_BITS-1:0];
            @(posedge clk); #1;          // 1-cycle synchronous read
            if (mem_rdata !== sent[i]) begin
                if (mismatches < 8)
                    $display("  MISMATCH @%0d: got %02x expected %02x", i, mem_rdata, sent[i]);
                mismatches = mismatches + 1;
            end
        end

        $display("address mismatches = %0d / %0d", mismatches, PAYLOAD);

        // ---- Check 3: DMA re-arms for the next frame ----
        // Tell the DMA the GPU is done, then stream a second (short) payload and
        // confirm the write pointer rewound to 0.
        start_seen = 1'b0;
        @(posedge clk); gpu_done = 1'b1;   // assert just after an edge,
        @(posedge clk); gpu_done = 1'b0;   // sampled cleanly on the next edge
        repeat (4) @(posedge clk);
        for (i = 0; i < 5; i = i + 1) begin
            sent[i] = (i * 37 + 200) & 8'hFF;   // fresh pattern
            uart_send(sent[i]);
        end
        // (793-byte payload not completed, so gpu_start stays low; just verify the
        //  5 fresh bytes overwrote addresses 0..4 — i.e. the pointer rewound.)
        mismatches2 = 0;
        for (i = 0; i < 5; i = i + 1) begin
            mem_raddr = i[ADDR_BITS-1:0];
            @(posedge clk); #1;
            if (mem_rdata !== sent[i]) mismatches2 = mismatches2 + 1;
        end
        $display("re-arm mismatches  = %0d / 5 (loading=%0b, expect 1 mid-reload)", mismatches2, loading);

        if (phase1_start && phase1_released && mismatches == 0 && mismatches2 == 0 && loading)
            $display("RESULT: PASS - %0d-byte transfer + re-arm both clean", PAYLOAD);
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
