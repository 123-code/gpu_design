`default_nettype none
`timescale 1ns/1ns

module gpu (
    input wire clk,//clock input
    input wire reset,//reset signal, clears internal states to 0
    input wire enable,//when on, gpu issues thread blocks
    output wire [7:0] result,//result from core 0
    output wire done,//when high, gpu has finished
    output wire [2:0] debug_core_state,//for debuging , shows the internal state of each core
    output wire [15:0] debug_instruction,//explores current active instruction, allowing real time tracing

//ignore, was used when data was baked in
    input wire [5:0] operand_a,
    input wire [5:0] operand_b,

    // Instruction RAM write ports
    input wire        instr_we,
    input wire [7:0]  instr_waddr,
    input wire [15:0] instr_wdata,

    // Core 0's private data-memory ports
    output wire [12:0] mem_raddr,//address requested from core 0, to read main darta from memory
    input  wire [7:0] mem_rdata,//data from main memory

    // Core 1's private data-memory ports (each core owns one BRAM copy;
    // the DMA broadcasts the payload into both)
    output wire [12:0] mem_raddr_1,
    input  wire [7:0]  mem_rdata_1,

    output wire       emit_valid,
    output wire [7:0] emit_data,
    input  wire       emit_ready,

    output wire        mem_we,//if core 0 executes a write insturction, it is enabled
    output wire [12:0] mem_waddr, //address requested from core 0, to write main darta to memory
    output wire [7:0]  mem_wdata, //data to be written to main memory from core 0

    output wire        mem_we_1,
    output wire [12:0] mem_waddr_1,
    output wire [7:0]  mem_wdata_1
);
//outputs from dispatcher, core begins execution
    wire core_0_start, core_1_start;
    wire core_0_done, core_1_done;
    //infroms core which block of data it is processing
    wire [7:0] core_0_id, core_1_id;

//dispatcher hands block 0 to core 0 and block 1 to core 1, and owns `done`
//(high once BOTH cores have finished their block)
    dispatcher #(
        .TOTAL_BLOCKS(2)
    ) main_dispatcher (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .core_0_done(core_0_done),
        .core_1_done(core_1_done),
        .core_0_start(core_0_start),
        .core_1_start(core_1_start),
        .core_0_id(core_0_id),
        .core_1_id(core_1_id),
        .done(done)
    );


    wire [7:0] core_0_instruction_address; //program counter output channel of core 0
    wire [15:0] current_instruction;//current instruction

    assign debug_instruction = current_instruction;//debugging

    program_memory rom (
        .clk(clk),
        // Listen to Core 0's PC
        .address(core_0_instruction_address),
        // Output the 16-bit instruction
        .instruction(current_instruction),
        // Live operands patched into the kernel
        .operand_a(operand_a),
        .operand_b(operand_b),
        .we(instr_we),
        .waddr(instr_waddr),
        .wdata(instr_wdata)
    );

    // Core 1's own copy of the kernel ROM. The cores run independent PCs, so
    // they can't share the single BRAM read port; duplicating the small ROM
    // is the cheapest second port.
    wire [7:0]  core_1_instruction_address;
    wire [15:0] current_instruction_1;

    program_memory rom_1 (
        .clk(clk),
        .address(core_1_instruction_address),
        .instruction(current_instruction_1),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .we(instr_we),
        .waddr(instr_waddr),
        .wdata(instr_wdata)
    );


    // Per-core emit handshakes, arbitrated onto the single UART (FSM below)
    wire       c0_emit_valid, c1_emit_valid;
    wire [7:0] c0_emit_data,  c1_emit_data;
    wire       c0_emit_ready, c1_emit_ready;

    // COMPUTE CORE 0 (Fully Wired)
    core #(
        .THREADS_PER_BLOCK(4)
    ) compute_core_0 (
        .clk(clk),
        .reset(reset),
        .start(core_0_start),
        .block_id(core_0_id),
        .done(core_0_done),

        // NEW: Plug into the ROM!
        .instruction_address(core_0_instruction_address),
        .current_instruction(current_instruction),

        // Expose the result to the top level
        .result(result),
        .debug_core_state(debug_core_state),

        // Data memory read port
        .mem_raddr(mem_raddr),
        .mem_rdata(mem_rdata),

        // Memory-mapped emit (arbitrated below: core 0's bytes go first)
        .emit_valid(c0_emit_valid),
        .emit_data(c0_emit_data),
        .emit_ready(c0_emit_ready),

        // Data-memory write port
        .mem_we(mem_we),
        .mem_waddr(mem_waddr),
        .mem_wdata(mem_wdata)
    );

    // COMPUTE CORE 1 (own ROM copy + own data-memory copy). Its emit goes
    // through the same UART, after core 0's bytes (see the emit FSM below);
    // until then its LSU just stalls on the handshake.
    core #(
        .THREADS_PER_BLOCK(4)
    ) compute_core_1 (
        .clk(clk),
        .reset(reset),
        .start(core_1_start),
        .block_id(core_1_id),
        .done(core_1_done),
        .instruction_address(core_1_instruction_address),
        .current_instruction(current_instruction_1),
        .result(),
        .debug_core_state(),
        .mem_raddr(mem_raddr_1),
        .mem_rdata(mem_rdata_1),
        .emit_valid(c1_emit_valid),
        .emit_data(c1_emit_data),
        .emit_ready(c1_emit_ready),
        .mem_we(mem_we_1),
        .mem_waddr(mem_waddr_1),
        .mem_wdata(mem_wdata_1)
    );

    // ------------------------------------------------------------------
    // Emit path + per-core cycle counters.
    //
    // Per run the host receives a fixed 8-byte reply:
    //   [core 0 kernel bytes][core 0 cycles x3 MSB-first]
    //   [core 1 kernel bytes][core 1 cycles x3 MSB-first]
    //
    // Core 0 is always served first; the switch to core 1 happens only once
    // core 0 is terminally done (its scheduler's DONE state is sticky and it
    // can never emit again), so the handoff can't tear a byte. Core 1's LSU
    // simply holds emit_valid until its turn — that's the normal handshake
    // stall, and it means cnt1 measures completion time including the wait
    // for core 0's UART bytes.
    // ------------------------------------------------------------------
    reg [23:0] cnt0, cnt1;  // 24 bits @ 27 MHz wraps at 0.62 s; a run is ~20 ms
    always @(posedge clk) begin
        if (reset) begin
            cnt0 <= 24'd0;
            cnt1 <= 24'd0;
        end else if (enable) begin
            if (!core_0_done) cnt0 <= cnt0 + 24'd1;
            if (!core_1_done) cnt1 <= cnt1 + 24'd1;
        end
    end

    localparam E_CORE0 = 3'd0, E_CNT0 = 3'd1,
               E_CORE1 = 3'd2, E_CNT1 = 3'd3, E_END = 3'd4;
    reg [2:0] estate;
    reg [1:0] bidx;  // counter byte being sent: 2 = MSB ... 0 = LSB

    wire [23:0] cnt_cur  = (estate == E_CNT0) ? cnt0 : cnt1;
    wire [7:0]  cnt_byte = (bidx == 2'd2) ? cnt_cur[23:16]
                         : (bidx == 2'd1) ? cnt_cur[15:8]
                         :                  cnt_cur[7:0];

    always @(posedge clk) begin
        if (reset) begin
            estate <= E_CORE0;
            bidx   <= 2'd2;
        end else begin
            case (estate)
                E_CORE0: if (core_0_done && !c0_emit_valid) begin
                             estate <= E_CNT0;
                             bidx   <= 2'd2;
                         end
                E_CNT0:  if (emit_ready) begin
                             if (bidx == 2'd0) estate <= E_CORE1;
                             else              bidx   <= bidx - 2'd1;
                         end
                E_CORE1: if (core_1_done && !c1_emit_valid) begin
                             estate <= E_CNT1;
                             bidx   <= 2'd2;
                         end
                E_CNT1:  if (emit_ready) begin
                             if (bidx == 2'd0) estate <= E_END;
                             else              bidx   <= bidx - 2'd1;
                         end
                default: ;
            endcase
        end
    end

    assign emit_valid = (estate == E_CORE0) ? c0_emit_valid
                      : (estate == E_CORE1) ? c1_emit_valid
                      : (estate == E_CNT0 || estate == E_CNT1) ? 1'b1
                      : 1'b0;
    assign emit_data  = (estate == E_CORE0) ? c0_emit_data
                      : (estate == E_CORE1) ? c1_emit_data
                      : cnt_byte;
    assign c0_emit_ready = (estate == E_CORE0) && emit_ready;
    assign c1_emit_ready = (estate == E_CORE1) && emit_ready;

endmodule
