`default_nettype none
`timescale 1ns/1ns

module core #(
    parameter THREADS_PER_BLOCK = 4,
    parameter ADDR_BITS = 13
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

    // Memory-mapped emit (thread 0's STR to offset 63 -> UART TX)
    output wire                 emit_valid,
    output wire [7:0]           emit_data,
    input  wire                 emit_ready,

    // Data-memory WRITE port (thread 0's STR to a non-MMIO address -> main_memory)
    output wire                 mem_we,
    output wire [ADDR_BITS-1:0]  mem_waddr,
    output wire [7:0]            mem_wdata,

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
    wire decoded_base_add;
    wire decoded_wbase_add;
    wire decoded_fc_clear;
    wire decoded_fc_mac;
    wire decoded_fc_arg;
    wire decoded_fc_read;

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
        .decoded_mac_load(decoded_mac_load),
        .decoded_base_add(decoded_base_add),
        .decoded_wbase_add(decoded_wbase_add),
        .decoded_fc_clear(decoded_fc_clear),
        .decoded_fc_mac(decoded_fc_mac),
        .decoded_fc_arg(decoded_fc_arg),
        .decoded_fc_read(decoded_fc_read)
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
    wire [ADDR_BITS-1:0] lsu_mem_addr [THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_mem_write_data [THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0] arb_ready;
    wire [7:0] arb_rdata [THREADS_PER_BLOCK-1:0];

    // Per-thread emit; only thread 0's reaches the UART (one feature map).
    wire [THREADS_PER_BLOCK-1:0] lsu_emit_valid;
    wire [7:0] lsu_emit_data [THREADS_PER_BLOCK-1:0];
    assign emit_valid = lsu_emit_valid[0];
    assign emit_data  = lsu_emit_data[0];

    // Per-thread memory writes; only thread 0's reaches main memory (SIMT-uniform
    // store model, like emit). Divergent per-thread writes would need an arbiter.
    wire [THREADS_PER_BLOCK-1:0]  lsu_we;
    wire [ADDR_BITS-1:0]          lsu_waddr [THREADS_PER_BLOCK-1:0];
    wire [7:0]                    lsu_wdata [THREADS_PER_BLOCK-1:0];
    assign mem_we    = lsu_we[0];
    assign mem_waddr = lsu_waddr[0];
    assign mem_wdata = lsu_wdata[0];

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
    // Pixel buffer only: the 9 conv weights are CONSTANT (part of the trained
    // model) and baked below, so a conv window just pushes 9 pixels with MACL.
    reg  [7:0] mac_buf [0:8];
    reg  [3:0] mac_wptr;
    wire       mac_fire = decoded_reg_write_enable && (decoded_reg_input_mux == 2'b11)
                          && !decoded_fc_read;

    always @(posedge clk) begin
        if (reset) begin
            mac_wptr <= 4'd0;
        end else if (core_state == UPDATE_STATE) begin
            if (decoded_mac_load && mac_wptr < 4'd9) begin
                mac_buf[mac_wptr] <= rs_bus[0];     // push a pixel
                mac_wptr <= mac_wptr + 4'd1;
            end else if (mac_fire) begin
                mac_wptr <= 4'd0;                   // consumed -> ready for next window
            end
        end
    end

    // Baked 3x3 conv weights (signed int8), loaded at synthesis from the trained
    // model. Override with -DCONV_W_HEX="..." in sim.
`ifndef CONV_W_HEX
    `define CONV_W_HEX "/Users/joseignacio/tiny-gpu-fpga/software/mnist_data/conv_weights.hex"
`endif
    reg signed [7:0] conv_w [0:8];
    initial $readmemh(`CONV_W_HEX, conv_w);

    wire [7:0] mac_result;
    mac_array_3x3 u_mac (
        .clk(clk),
        .rst_n(~reset),
        .valid_in(1'b1),
        .px00(mac_buf[0]), .px01(mac_buf[1]),  .px02(mac_buf[2]),
        .px10(mac_buf[3]), .px11(mac_buf[4]),  .px12(mac_buf[5]),
        .px20(mac_buf[6]), .px21(mac_buf[7]),  .px22(mac_buf[8]),
        .w00(conv_w[0]),   .w01(conv_w[1]),    .w02(conv_w[2]),
        .w10(conv_w[3]),   .w11(conv_w[4]),    .w12(conv_w[5]),
        .w20(conv_w[6]),   .w21(conv_w[7]),    .w22(conv_w[8]),
        .pixel_out(mac_result),
        .valid_out()
    );

    // ==========================================
    // THE FC-MAC FUNCTIONAL UNIT (shared, core-level)
    // ==========================================
    // Wide (32-bit) accumulator for the fully-connected layer: thread 0 drives
    // it (SIMT-uniform). FCLR/FMAC act in UPDATE; FRD reads it back through the
    // MAC writeback mux (mux==11 with decoded_fc_read selecting fc over conv).
    wire [7:0] fc_result;
    fc_mac u_fc (
        .clk(clk),
        .reset(reset),
        .frst  (decoded_fc_clear && (core_state == UPDATE_STATE)),
        .mac_en(decoded_fc_mac   && (core_state == UPDATE_STATE)),
        .farg  (decoded_fc_arg   && (core_state == UPDATE_STATE)),
        .px(rs_bus[0]),
        .wt(rt_bus[0]),
        .result(fc_result)
    );

    // Writeback source for the shared MAC mux: conv MAC normally, FC readout on FRD.
    wire [7:0] mac_or_fc_result = decoded_fc_read ? fc_result : mac_result;

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

                .mac_result(mac_or_fc_result),
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

            // Real LSU (base+offset addressing into main_memory via the arbiter)
            lsu #(.ADDR_BITS(ADDR_BITS)) thread_lsu (
                .clk(clk),
                .reset(reset),
                .enable(1'b1),
                .core_state(core_state),

                .decoded_mem_read(decoded_mem_read_enable),
                .decoded_mem_write(decoded_mem_write_enable),
                .decoded_base_add(decoded_base_add),
                .decoded_wbase_add(decoded_wbase_add),
                .decoded_immediate(decoded_immediate),

                .rs(rs_bus[i]),
                .rt(rt_bus[i]),

                .mem_valid(lsu_mem_valid[i]),
                .mem_addr(lsu_mem_addr[i]),
                .mem_write_data(lsu_mem_write_data[i]),
                .mem_ready(arb_ready[i]),
                .mem_read_data(arb_rdata[i]),

                .mem_we(lsu_we[i]),
                .mem_waddr(lsu_waddr[i]),
                .mem_wdata(lsu_wdata[i]),

                .emit_valid(lsu_emit_valid[i]),
                .emit_data(lsu_emit_data[i]),
                .emit_ready(emit_ready),

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