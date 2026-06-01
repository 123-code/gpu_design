`default_nettype none
`timescale 1ns/1ns

module gpu (
    input wire clk,
    input wire reset,
    input wire enable,

    // Observability for the board: core 0's result (R3) and its done flag
    output wire [7:0] result,
    output wire done,

    // Extra debug taps for hardware bring-up
    output wire [2:0] debug_core_state,
    output wire [15:0] debug_instruction,

    // Runtime operands (from UART) injected into the kernel's MOV immediates
    input wire [5:0] operand_a,  // -> R4 (addend)
    input wire [5:0] operand_b,  // -> R2 (loop count)

    // Core 0's data-memory read port (to main_memory via the system top)
    output wire [9:0] mem_raddr,
    input  wire [7:0] mem_rdata,

    // Core 0's memory-mapped emit (STR -> UART TX)
    output wire       emit_valid,
    output wire [7:0] emit_data,
    input  wire       emit_ready
);

    wire core_0_start, core_1_start;
    wire core_0_done, core_1_done;
    wire [7:0] core_0_id, core_1_id;

    assign done = core_0_done;

    dispatcher #(
        .TOTAL_BLOCKS(4)
    ) main_dispatcher (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .core_0_done(core_0_done),
        .core_1_done(core_1_done),
        .core_0_start(core_0_start),
        .core_1_start(core_1_start),
        .core_0_id(core_0_id),
        .core_1_id(core_1_id)
    );

    // ==========================================
    // THE INSTRUCTION DATAPATH (The Spine)
    // ==========================================
    wire [7:0] core_0_instruction_address;
    wire [15:0] current_instruction;

    assign debug_instruction = current_instruction;

    program_memory rom (
        .clk(clk),
        // Listen to Core 0's PC
        .address(core_0_instruction_address),
        // Output the 16-bit instruction
        .instruction(current_instruction),
        // Live operands patched into the kernel
        .operand_a(operand_a),
        .operand_b(operand_b)
    );

    // ==========================================
    // COMPUTE CORE 0 (Fully Wired!)
    // ==========================================
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

        // Memory-mapped emit
        .emit_valid(emit_valid),
        .emit_data(emit_data),
        .emit_ready(emit_ready)
    );

    // (Compute Core 1 left disconnected from ROM for this specific simulation test)
    core #(
        .THREADS_PER_BLOCK(4)
    ) compute_core_1 (
        .clk(clk),
        .reset(reset),
        .start(core_1_start),
        .block_id(core_1_id),
        .done(core_1_done),
        .instruction_address(),
        .current_instruction(16'd0),
        .mem_raddr(),
        .mem_rdata(8'd0),
        .emit_valid(),
        .emit_data(),
        .emit_ready(1'b0)
    );

endmodule