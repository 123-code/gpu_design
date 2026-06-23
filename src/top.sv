`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Tang Nano 20K top-level: a host-driven accelerator.
//
//   Mac --UART--> data_pipeline (uart_rx -> DMA -> main_memory)
//                      │ gpu_start (payload loaded)      ▲ gpu_done
//                      ▼                                 │
//                 GPU runs its kernel, LDR-ing data out of main_memory
//                      │
//                      └─ result -> LEDs + UART TX
//
// The GPU sits completely idle until the DMA finishes loading a payload and
// pulses gpu_start (no power-on auto-run). Everything is on one 27 MHz clock.
// ============================================================================
module top #(
    // Full on-chip MNIST (mnist_full.asm): the host streams TWO 784-byte
    // 28x28 images per run (one per core); all weights/biases are baked, and
    // each core runs the whole Conv->Pool->Scatter->FC pipeline on its image.
    // Reply: [digit0][cycles0 x3][digit1][cycles1 x3] = 8 bytes.
    parameter PAYLOAD_BYTES = 1568,      // 2 x 784
    parameter CLK_FREQ      = 27000000,  // for the UART bit timing (override in sim)
    parameter BAUD_RATE     = 115200, //baud rate
    parameter BLOCK_DIM     = 4          // threads per block (4 = one warp/core; 8 = both warps)
) (
    input  wire       clk,          // 27 MHz crystal  (PIN 4)
    input  wire       uart_rx_in,    // from host       (PIN 70)
    output wire       uart_tx_out,   // to host         (PIN 69)
    output wire [5:0] led            // leds to show result on them
);
    // ---- system power-on reset, holds on closed for 15 clock cycles ----
    reg [3:0] por = 4'd0; //forcing the counter to wake up at 0 
    wire por_done = &por;

    //on every clock tick, the circuit checks the por done wire, if 0, we route por through adder  to count 
    // if por is 1, the statement becomes false and the counter stays frozen
    always @(posedge clk) if (!por_done) por <= por + 1'b1;
    // we neeed to flip the por done wire, because it is a 1 when "ready to run" but sys reset is 0 when ready to run
    //ys reset means essentially : "should everything be kept rozen?"
    wire sys_reset = !por_done;

    // ---- Host-to-Device pipeline ----
    wire        gpu_start, loading; // gpu start is high when the image was loaded loading is high while image is still loading from dma
    wire        instr_we;
    wire [7:0]  instr_waddr;
    wire [15:0] instr_wdata;
    wire [12:0] mem_raddr;            //address to read from 4096 memory
    wire [7:0]  mem_rdata;//data to be read from 4096 memory
    wire        gpu_we;               // GPU write port on when gpu writes to memory
    wire [12:0] gpu_waddr;//address where data is written to
    wire [7:0]  gpu_wdata;
    // core 1's ports into its own memory copy
    wire [12:0] mem_raddr_1;
    wire [7:0]  mem_rdata_1;
    wire        gpu_we_1;
    wire [12:0] gpu_waddr_1;
    wire [7:0]  gpu_wdata_1;
    wire        done;                 // GPU finished a run,fed back, so dma can get new data
    wire [7:0]  result;               //predicted (in this case 8 bits because it is a digit)

    data_pipeline #(
        .ADDR_BITS(13),
        .PAYLOAD_BYTES(PAYLOAD_BYTES),
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) pipe (
        .clk(clk), .reset(sys_reset),
        .uart_rx_in(uart_rx_in),
        .gpu_done(done),              // GPU done -> DMA re-arms for next frame
        .gpu_start(gpu_start),
        .loading(loading),
        .instr_we(instr_we),
        .instr_waddr(instr_waddr),
        .instr_wdata(instr_wdata),
        .mem_raddr(mem_raddr),
        .mem_rdata(mem_rdata),
        .gpu_we(gpu_we),
        .gpu_waddr(gpu_waddr),
        .gpu_wdata(gpu_wdata),
        .mem_raddr_1(mem_raddr_1),
        .mem_rdata_1(mem_rdata_1),
        .gpu_we_1(gpu_we_1),
        .gpu_waddr_1(gpu_waddr_1),
        .gpu_wdata_1(gpu_wdata_1)
    );

    // ---- GPU run control: idle until a payload is ready ----
    // On gpu_start, briefly hold reset then release + enable for exactly one run.
    reg        armed  = 1'b0;//gpu start wire on, starts at 0, fires when on 
    reg [4:0]  runrst = 5'd0;//5 bit counter
    always @(posedge clk) begin
        if (sys_reset)        begin armed <= 1'b0; runrst <= 5'd0; end
        //if gpu start, we set the armed register to 1 and the runrst counter to 0
        else if (gpu_start)   begin armed <= 1'b1; runrst <= 5'd0; end // new run
        else if (armed && !(&runrst)) runrst <= runrst + 1'b1;
    end
    wire gpu_reset  = sys_reset || !armed || !(&runrst); //on when chip on power reset, no job armed, startup countdown not finished
    wire gpu_enable = armed && (&runrst); //on when job armed, startup countdown finished

    // ---- the GPU ----
    wire       emit_valid;//valid data to be sent out 
    wire [7:0] emit_data;//byte ti send
    reg        emit_ready;//ready to send out data
//ports open to the gpu, ehich contsins dispatecer, program memory,compute cores
    gpu #(.BLOCK_DIM(BLOCK_DIM)) uut (
        .clk(clk),
        .reset(gpu_reset),
        .enable(gpu_enable),
        .result(result),
        .done(done),
        .debug_core_state(),
        .debug_instruction(),
        .operand_a(6'd0),             // operand-injection unused in host-driven mode
        .operand_b(6'd0),
        .instr_we(instr_we),
        .instr_waddr(instr_waddr),
        .instr_wdata(instr_wdata),
        .mem_raddr(mem_raddr),
        .mem_rdata(mem_rdata),
        .mem_we(gpu_we),
        .mem_waddr(gpu_waddr),
        .mem_wdata(gpu_wdata),
        .mem_raddr_1(mem_raddr_1),
        .mem_rdata_1(mem_rdata_1),
        .mem_we_1(gpu_we_1),
        .mem_waddr_1(gpu_waddr_1),
        .mem_wdata_1(gpu_wdata_1),
        .emit_valid(emit_valid),
        .emit_data(emit_data),
        .emit_ready(emit_ready)
    );

//fsm,pulses tx_start once to start uart_txand waits while busy then pulses emit ready so gpu can send the next byte
    wire uart_busy;
    reg  tx_start;
    localparam E_IDLE = 2'd0, E_SEND = 2'd1, E_WAIT = 2'd2;
    reg [1:0] estate;
    always @(posedge clk) begin
        if (sys_reset) begin
            estate <= E_IDLE; tx_start <= 1'b0; emit_ready <= 1'b0;
        end else begin
            tx_start <= 1'b0; emit_ready <= 1'b0;
            case (estate)
                // !emit_ready: during the ack cycle the GPU hasn't dropped
                // emit_valid yet (its FSM is registered); launching then would
                // send every byte twice.
                E_IDLE: if (emit_valid && !uart_busy && !emit_ready) begin
                            tx_start <= 1'b1;            // launch emit_data
                            estate   <= E_SEND;
                        end
                E_SEND: if (uart_busy) estate <= E_WAIT; // byte started
                E_WAIT: if (!uart_busy) begin            // byte fully sent
                            emit_ready <= 1'b1;          // ack the GPU's STR
                            estate     <= E_IDLE;
                        end
            endcase
        end
    end

    uart_tx #(.BAUD_LIMIT(CLK_FREQ / BAUD_RATE)) u_tx (
        .clk(clk), .reset(sys_reset),
        .data_in(emit_data), .tx_start(tx_start),
        .tx_out(uart_tx_out), .tx_busy(uart_busy)
    );

    // ---- LEDs: loading status + done + low nibble of the result ----
    assign led = ~{loading, done, result[3:0]};

endmodule
