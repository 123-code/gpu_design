`default_nettype none
`timescale 1ns/1ns

module core #(
    parameter THREADS_PER_BLOCK = 4,
    parameter ADDR_BITS = 10
) (
    input wire clk,
    input wire reset,
    input wire start,
    input wire [7:0] block_id,
    output wire done,

    // ==========================================
    // DATA MEMORY READ PORT (serialized across threads by lsu_arbiter)
    // ==========================================
    output wire [ADDR_BITS-1:0] mem_raddr,
    input  wire [7:0]           mem_rdata,

    // ==========================================
    // NEW: THE MEMORY SPINE
    // ==========================================
    output wire [7:0] instruction_address, // Asking the ROM for code
    input wire [15:0] current_instruction, // Receiving the code from ROM

    // Debug tap: thread 0's R3 (the accumulator) for the LED display
    output wire [7:0] result,

    // Debug tap: the scheduler FSM state, for hardware bring-up visibility
    output wire [2:0] debug_core_state
);

    wire [2:0] core_state;
    assign debug_core_state = core_state;
    wire [1:0] lsu_states [THREADS_PER_BLOCK-1:0];

    // ==========================================
    // DECODER DATAPATH WIRES (real ports from decoder.sv)
    // ==========================================
    wire [3:0] decoded_rd_address;
    wire [3:0] decoded_rs_address;
    wire [3:0] decoded_rt_address;
    wire [2:0] decoded_nzp;
    wire [7:0] decoded_immediate;

    wire decoded_reg_write_enable;
    wire decoded_mem_read_enable;
    wire decoded_mem_write_enable;
    wire decoded_nzp_write_enable;
    wire [1:0] decoded_reg_input_mux;
    wire [1:0] decoded_alu_arithmetic_mux;
    wire decoded_alu_output_mux;
    wire decoded_pc_mux;
    wire decoded_ret;
    wire decoded_mac_load;

    // ==========================================
    // INSTANTIATE THE (REAL) DECODER
    // ==========================================
    decoder core_decoder (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .instruction(current_instruction),

        .decoded_rd_address(decoded_rd_address),
        .decoded_rs_address(decoded_rs_address),
        .decoded_rt_address(decoded_rt_address),
        .decoded_nzp(decoded_nzp),
        .decoded_immediate(decoded_immediate),

        .decoded_reg_write_enable(decoded_reg_write_enable),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_nzp_write_enable(decoded_nzp_write_enable),

        .decoded_reg_input_mux(decoded_reg_input_mux),
        .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
        .decoded_alu_output_mux(decoded_alu_output_mux),
        .decoded_pc_mux(decoded_pc_mux),
        .decoded_ret(decoded_ret),
        .decoded_mac_load(decoded_mac_load)
    );

    // ==========================================
    // THE SCHEDULER
    // ==========================================
    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) core_scheduler (
        .clk(clk),
        .reset(reset),
        .start(start),
        .decoded_ret(decoded_ret), // It is finally alive!
        .lsu_state(lsu_states),
        .core_state(core_state),
        .done(done)
    );

    // ==========================================
    // THE THREAD GRID
    // ==========================================
    wire [7:0] rs_bus [THREADS_PER_BLOCK-1:0];
    wire [7:0] rt_bus [THREADS_PER_BLOCK-1:0];
    wire [7:0] alu_out_bus [THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_out_bus [THREADS_PER_BLOCK-1:0];
    wire [7:0] reg3_bus [THREADS_PER_BLOCK-1:0];

    // Expose thread 0's accumulator as this core's result
    assign result = reg3_bus[0];
    
    // PC bus (we drive it from next_pc for thread 0 for ROM fetches)
    wire [7:0] pc_bus [THREADS_PER_BLOCK-1:0];
    wire [7:0] next_pc_bus [THREADS_PER_BLOCK-1:0];

    // Per-thread LSU memory request/response wires (serviced by lsu_arbiter).
    wire lsu_mem_valid [THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_mem_addr [THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_mem_write_data [THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0] arb_ready;
    wire [7:0] arb_rdata [THREADS_PER_BLOCK-1:0];

    // Pack the per-thread valid flags into a bus for the arbiter.
    wire [THREADS_PER_BLOCK-1:0] lsu_req;
    genvar v;
    generate
        for (v = 0; v < THREADS_PER_BLOCK; v = v + 1)
            assign lsu_req[v] = lsu_mem_valid[v];
    endgenerate

    // 4 -> 1 read-port arbiter (snapshot-and-drain; latency hidden in WAIT state).
    lsu_arbiter #(
        .THREADS(THREADS_PER_BLOCK),
        .ADDR_BITS(ADDR_BITS)
    ) core_lsu_arbiter (
        .clk(clk),
        .reset(reset),
        .req(lsu_req),
        .addr(lsu_mem_addr),
        .mem_raddr(mem_raddr),
        .mem_rdata(mem_rdata),
        .ready(arb_ready),
        .rdata(arb_rdata)
    );

    // Thread 0's PC drives the instruction ROM address (simple skeleton)
    assign instruction_address = pc_bus[0];

    // ==========================================
    // THE 3x3 MAC FUNCTIONAL UNIT (shared, core-level)
    // ==========================================
    // An 18-byte operand buffer bridges the "18 operands vs 2-operand datapath"
    // gap: MACL pushes one register per instruction (9 pixels, then 9 weights);
    // MAC reads the unit's result. Thread 0 drives the buffer (SIMT-uniform).
    localparam UPDATE_STATE = 3'b110;
    reg  [7:0] mac_buf [0:17];
    reg  [4:0] mac_wptr;
    wire       mac_fire = decoded_reg_write_enable && (decoded_reg_input_mux == 2'b11);

    always @(posedge clk) begin
        if (reset) begin
            mac_wptr <= 5'd0;
        end else if (core_state == UPDATE_STATE) begin
            if (decoded_mac_load && mac_wptr < 5'd18) begin
                mac_buf[mac_wptr] <= rs_bus[0];     // push this operand
                mac_wptr <= mac_wptr + 5'd1;
            end else if (mac_fire) begin
                mac_wptr <= 5'd0;                   // consumed -> ready for next conv
            end
        end
    end

    wire [7:0] mac_result;
    mac_array_3x3 u_mac (
        .clk(clk),
        .rst_n(~reset),
        .valid_in(1'b1),
        .px00(mac_buf[0]), .px01(mac_buf[1]),  .px02(mac_buf[2]),
        .px10(mac_buf[3]), .px11(mac_buf[4]),  .px12(mac_buf[5]),
        .px20(mac_buf[6]), .px21(mac_buf[7]),  .px22(mac_buf[8]),
        .w00(mac_buf[9]),  .w01(mac_buf[10]),  .w02(mac_buf[11]),
        .w10(mac_buf[12]), .w11(mac_buf[13]),  .w12(mac_buf[14]),
        .w20(mac_buf[15]), .w21(mac_buf[16]),  .w22(mac_buf[17]),
        .pixel_out(mac_result),
        .valid_out()
    );

    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : thread_block
            
            // Real registers module ports. THREAD_ID(i) makes %threadIdx (R15)
            // hold this lane's index, so SIMT threads can address distinct data.
            registers #(
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .THREAD_ID(i)
            ) thread_regs (
                .clk(clk),
                .reset(reset),
                .enable(1'b1),
                .block_id(block_id),
                .core_state(core_state),

                .decoded_rd_address(decoded_rd_address),
                .decoded_rs_address(decoded_rs_address),
                .decoded_rt_address(decoded_rt_address),

                .decoded_reg_write_enable(decoded_reg_write_enable),
                .decoded_reg_input_mux(decoded_reg_input_mux),
                .decoded_immediate(decoded_immediate),

                .alu_out(alu_out_bus[i]),
                .lsu_out(lsu_out_bus[i]),

                .rs(rs_bus[i]),
                .rt(rt_bus[i]),

                .mac_result(mac_result),
                .debug_reg3(reg3_bus[i])
            );

            // Real (simple) ALU
            alu thread_alu (
                .clk(clk),
                .opcode(current_instruction[15:12]), 
                .imm(decoded_immediate),             
                .rs(rs_bus[i]),
                .rt(rt_bus[i]),
                .alu_out(alu_out_bus[i])
            );

            // Real LSU + dummy memory pins
            lsu thread_lsu (
                .clk(clk),
                .reset(reset),
                .enable(1'b1),
                .core_state(core_state),

                .decoded_mem_read(decoded_mem_read_enable),
                .decoded_mem_write(decoded_mem_write_enable),

                .rs(rs_bus[i]),
                .rt(rt_bus[i]),

                .mem_valid(lsu_mem_valid[i]),
                .mem_addr(lsu_mem_addr[i]),
                .mem_write_data(lsu_mem_write_data[i]),
                .mem_ready(arb_ready[i]),
                .mem_read_data(arb_rdata[i]),

                .lsu_state(lsu_states[i]),
                .lsu_out(lsu_out_bus[i])
            );

            // Real PC module — supply required decoder controls as 0 for skeleton
            pc thread_pc (
                .clk(clk),
                .reset(reset),
                .enable(1'b1),
                .core_state(core_state),

                .decoded_nzp(decoded_nzp),
                .decoded_immediate(decoded_immediate),
                .decoded_nzp_write_enable(decoded_nzp_write_enable),
                .decoded_pc_mux(decoded_pc_mux),

                .alu_out(alu_out_bus[i]),

                .current_pc(pc_bus[i]),
                .next_pc(next_pc_bus[i])
            );

            // Close the PC feedback loop: the current PC is just the registered
            // next_pc from pc.sv. pc.sv advances it (+1 or branch target) during
            // EXECUTE, so this acts as the program counter for sequential and
            // branching control flow alike.
            assign pc_bus[i] = next_pc_bus[i];
            
        end
    endgenerate

endmodule