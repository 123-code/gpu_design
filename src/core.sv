`default_nettype none
`timescale 1ns/1ns

module core #(
    parameter THREADS_PER_BLOCK = 4, // lanes per warp (the warp size)
    parameter WARPS_PER_CORE = 2,    // Stage 2: Multiple warps for latency hiding
    parameter BLOCK_DIM = THREADS_PER_BLOCK, // launch size: how many threads this block runs
    parameter ADDR_BITS = 13         // width of data memory address
) (
    input wire clk,//clock
    input wire reset,//reset signal
    input wire start,//cycle pulse from dispatcher, when 1, core begins execution
    input wire [7:0] block_id,//8 bit identfier, which block of data is this core processing
    output wire done,//when 1, core has finished processing

//dtata memory read (since multiple threads want to read simultaneously, read requests are serialized by arbiter)
    output wire [ADDR_BITS-1:0] mem_raddr,//address
    input  wire [7:0]           mem_rdata,//data

    // Memory-mapped emit (thread 0's STR to offset 63 -> UART TX)
    output wire                 emit_valid,
    output wire [7:0]           emit_data,
    input  wire                 emit_ready,

    // data write from threads back to ram
    output wire                 mem_we,//write eneble
    output wire [ADDR_BITS-1:0]  mem_waddr,//ram address where data will be stored
    output wire [7:0]            mem_wdata,//data to be stored in memory


    output wire [7:0] instruction_address, // Asking the ROM for code
    input wire [15:0] current_instruction, // Receiving the code from ROM

    // Debug tap: thread 0's R3 (the accumulator) for the LED display
    output wire [7:0] result,
    // Debug tap: the scheduler FSM state, for hardware bring-up visibility
    output wire [2:0] debug_core_state
);

    // 4-bit pipeline state, driven by the scheduler. Must match scheduler.sv:
    //   IDLE=0000 SELECT_WARP=0001 FETCH=0010 DECODE=0011 REQUEST=0100
    //   WAIT=0101 EXECUTE=0110 UPDATE=0111 DONE=1000
    wire [3:0] core_state;
    assign debug_core_state = core_state[2:0];
    wire [1:0] lsu_states [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0] active_mask [WARPS_PER_CORE-1:0];

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
    wire decoded_id_read;
    wire decoded_sync; // NEW
    wire [1:0] decoded_mac_byte; // which 8-bit slice of the 32-bit MAC/FC result
    
    wire current_warp;
    wire [WARPS_PER_CORE-1:0] warp_emit;   // per-warp: thread 0 has a UART emit in flight
    wire [THREADS_PER_BLOCK-1:0] branch_votes;
    wire [THREADS_PER_BLOCK-1:0] all_branch_votes [WARPS_PER_CORE-1:0];
    assign branch_votes = all_branch_votes[current_warp];

    wire [7:0] warp_pc [WARPS_PER_CORE-1:0];

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
        .decoded_fc_read(decoded_fc_read),
        .decoded_id_read(decoded_id_read),
        .decoded_sync(decoded_sync),
        .decoded_mac_byte(decoded_mac_byte)
    );

    // ==========================================
    // THE SCHEDULER
    // ==========================================
    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .WARPS_PER_CORE(WARPS_PER_CORE),
        .BLOCK_DIM(BLOCK_DIM)
    ) core_scheduler (
        .clk(clk),
        .reset(reset),
        .start(start),
        .decoded_ret(decoded_ret), // It is finally alive!
        .lsu_state(lsu_states),
        
        .decoded_sync(decoded_sync),
        .decoded_pc_mux(decoded_pc_mux),
        .decoded_immediate(decoded_immediate),
        .branch_votes(branch_votes),
        .warp_emit(warp_emit),
        
        .current_warp(current_warp),
        .warp_pc(warp_pc),

        .core_state(core_state),
        .done(done),
        .active_mask(active_mask)
    );

    // ==========================================
    // THE THREAD GRID
    // ==========================================
    wire [7:0] rs_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] rt_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] alu_out_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_out_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] reg3_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];

    // Expose Warp 0 Thread 0's accumulator as this core's result
    assign result = reg3_bus[0][0];
    
    // PC bus
    wire [7:0] pc_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] next_pc_bus [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];

    // Shared ALU inputs and outputs (Multiplexed by current_warp)
    wire [7:0] active_rs [THREADS_PER_BLOCK-1:0];
    wire [7:0] active_rt [THREADS_PER_BLOCK-1:0];
    wire [7:0] active_alu_out [THREADS_PER_BLOCK-1:0];

    // Flattened arrays for LSU Arbiter
    wire [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0] lsu_req;
    wire [ADDR_BITS-1:0] lsu_addr [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0];
    wire [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0] arb_ready;
    wire [7:0] arb_rdata [WARPS_PER_CORE*THREADS_PER_BLOCK-1:0];

    // Per-warp/thread wires for LSU
    wire lsu_mem_valid [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [ADDR_BITS-1:0] lsu_mem_addr [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_mem_write_data [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];

    wire lsu_emit_valid [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_emit_data [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];

    // ---- Emit ownership latch ----
    // A warp emits (thread 0 STR to offset 63) by raising lsu_emit_valid[w][0]
    // and holding it until emit_ready. The scheduler can context-switch away
    // mid-handshake, so route the UART by a LATCHED owner (held until the byte
    // is acked) rather than current_warp, and steer emit_ready to that owner
    // only — otherwise a context switch tears/misroutes the byte. (Hardcoded for
    // 2 warps, matching the rest of the multi-warp logic.)
    reg emit_owned;
    reg emit_owner;                  // 1-bit owner id (WARPS_PER_CORE <= 2)
    integer ew;
    reg     ew_found;
    always @(posedge clk) begin
        if (reset) begin
            emit_owned <= 1'b0;
            emit_owner <= 1'b0;
        end else if (!emit_owned) begin
            // Lowest-index warp with thread 0's emit valid claims the UART (loop
            // form so it works for any WARPS_PER_CORE, including 1).
            ew_found = 1'b0;
            for (ew = 0; ew < WARPS_PER_CORE; ew = ew + 1) begin
                if (!ew_found && lsu_emit_valid[ew][0]) begin
                    emit_owned <= 1'b1;
                    emit_owner <= ew[0];
                    ew_found = 1'b1;
                end
            end
        end else if (emit_ready) begin
            emit_owned <= 1'b0;                 // byte acked -> release the UART
        end
    end
    assign emit_valid = emit_owned && lsu_emit_valid[emit_owner][0];
    assign emit_data  = lsu_emit_data[emit_owner][0];

    // Per-warp emit-in-flight flag for the scheduler's emit-stall (thread 0).
    genvar gw;
    generate
        for (gw = 0; gw < WARPS_PER_CORE; gw = gw + 1) begin : warp_emit_gen
            assign warp_emit[gw] = lsu_emit_valid[gw][0];
        end
    endgenerate

    wire lsu_we [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [ADDR_BITS-1:0] lsu_waddr [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    wire [7:0] lsu_wdata [WARPS_PER_CORE-1:0][THREADS_PER_BLOCK-1:0];
    assign mem_we    = lsu_we[current_warp][0];
    assign mem_waddr = lsu_waddr[current_warp][0];
    assign mem_wdata = lsu_wdata[current_warp][0];

    // Shared Arbiter (handles all warps and threads simultaneously)
    lsu_arbiter #(
        .THREADS(WARPS_PER_CORE * THREADS_PER_BLOCK),
        .ADDR_BITS(ADDR_BITS)
    ) core_lsu_arbiter (
        .clk(clk),
        .reset(reset),
        .req(lsu_req),
        .addr(lsu_addr),
        .mem_raddr(mem_raddr),
        .mem_rdata(mem_rdata),
        .ready(arb_ready),
        .rdata(arb_rdata)
    );

    // Thread 0's PC from the active warp drives the instruction ROM address
    assign instruction_address = warp_pc[current_warp];

    // ==========================================
    // THE VECTOR MAC FUNCTIONAL UNIT (shared, core-level)
    // ==========================================
    // vector_mac is a STATIC 8-lane multiply-accumulate: 8 parallel signed
    // multipliers + a fixed adder tree (see vector_mac.sv). It always sums all 8
    // lanes; there is no programmable length. Operands reach it through two 8-slot
    // buffers below: each MACL pushes one (pixel=rs, weight=rt) PAIR and bumps
    // mac_wptr (capped at 8); MAC then fires and reads the 8-lane dot product.
    // Push up to 8 pairs before firing; unused slots keep their previous value and
    // still contribute, so zero them (or push a full 8) if you need a shorter dot
    // product. Thread 0 drives the buffers (SIMT-uniform). For an arbitrary-length
    // accumulation use the FC unit instead (fc_mac.sv: FMAC accumulates per cycle).
    localparam UPDATE_STATE = 4'b0111;
    // Small operand buffers (stay in FFs: written at a variable index but read at
    // constant indices by vector_mac, so GowinSynthesis does not RAM-infer them).
    reg  [7:0] mac_buf [0:7];    // 8 pixel slots
    reg  [7:0] weight_buf [0:7]; // 8 weight slots
    reg  [3:0] mac_wptr;
    wire       mac_fire = decoded_reg_write_enable && (decoded_reg_input_mux == 2'b11)
                          && !decoded_fc_read;

    always @(posedge clk) begin
        if (reset) begin
            mac_wptr <= 4'd0;
        end else if (core_state == UPDATE_STATE) begin
            if (decoded_mac_load && mac_wptr < 4'd8) begin
                mac_buf[mac_wptr] <= rs_bus[current_warp][0];        // push a pixel from rs register
                weight_buf[mac_wptr] <= rt_bus[current_warp][0];     // push a weight from rt register we now load one weight and one pixel simultaneously
                mac_wptr <= mac_wptr + 4'd1;
            end else if (mac_fire) begin
                mac_wptr <= 4'd0;                      // consumed -> ready for next window
            end
        end
    end



    wire [31:0] vector_result_32;

    vector_mac u_mac (
        .clk(clk),
        .rst_n(~reset),
        .valid_in(1'b1),
        .px0(mac_buf[0]), .px1(mac_buf[1]), .px2(mac_buf[2]), .px3(mac_buf[3]),
        .px4(mac_buf[4]), .px5(mac_buf[5]), .px6(mac_buf[6]), .px7(mac_buf[7]),
        .w0(weight_buf[0]), .w1(weight_buf[1]), .w2(weight_buf[2]), .w3(weight_buf[3]),
        .w4(weight_buf[4]), .w5(weight_buf[5]), .w6(weight_buf[6]), .w7(weight_buf[7]),
        .result_out(vector_result_32),
        .valid_out()
    );

    // ==========================================
    // THE FC-MAC FUNCTIONAL UNIT (shared, core-level)
    // ==========================================
    // Wide (32-bit) accumulator for the fully-connected layer: thread 0 drives
    // it (SIMT-uniform). FCLR/FMAC act in UPDATE; FRD reads it back through the
    // MAC writeback mux (mux==11 with decoded_fc_read selecting fc over conv).
    wire [31:0] fc_result_32;

    fc_mac u_fc (
        .clk(clk),
        .reset(reset),
        .frst  (decoded_fc_clear && (core_state == UPDATE_STATE)),
        .mac_en(decoded_fc_mac   && (core_state == UPDATE_STATE)),
        .farg  (decoded_fc_arg   && (core_state == UPDATE_STATE)),
        .px(rs_bus[current_warp][0]),
        .wt(rt_bus[current_warp][0]),
        .bias_in({{24{rt_bus[current_warp][0][7]}}, rt_bus[current_warp][0]}), // Sign-extend, padding 8-bit bias to 32-bit bd sending to fc mac vector unit
        .result(fc_result_32)
    );

    // Writeback source for the shared MAC mux: conv MAC normally, FC readout on FRD.
    // Both units produce a 32-bit result; decoded_mac_byte (from MAC Rd,#n) picks
    // which 8-bit slice reaches the 8-bit register file, so software can pull the
    // whole 32-bit value out across four reads. Bare MAC / FBEST => byte 0 (LSB).
    wire [31:0] mac_or_fc_result_32 = decoded_fc_read ? fc_result_32 : vector_result_32;
    wire [7:0] mac_or_fc_result =
          (decoded_mac_byte == 2'd0) ? mac_or_fc_result_32[7:0]
        : (decoded_mac_byte == 2'd1) ? mac_or_fc_result_32[15:8]
        : (decoded_mac_byte == 2'd2) ? mac_or_fc_result_32[23:16]
        :                              mac_or_fc_result_32[31:24];

    genvar w, i;
    generate
        // Shared ALUs across all warps (Time-multiplexed execution units)
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : shared_alus
            assign active_rs[i] = rs_bus[current_warp][i];
            assign active_rt[i] = rt_bus[current_warp][i];

            alu thread_alu (
                .clk(clk),
                .opcode(current_instruction[15:12]), 
                .imm(decoded_immediate),             
                .rs(active_rs[i]),
                .rt(active_rt[i]),
                .alu_out(active_alu_out[i])
            );
        end

        // Independent state for each warp
        for (w = 0; w < WARPS_PER_CORE; w = w + 1) begin : warp_block
            wire warp_active_flag = (current_warp == w);
            for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : thread_block
                
                localparam flat_id = w * THREADS_PER_BLOCK + i;

                registers #(
                    .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                    // GLOBAL thread index: warp w lane i -> w*warpSize + i.
                    // (warp0 = 0..3, warp1 = 4..7) so the two warps cover
                    // DISTINCT threads instead of redundantly running 0..3.
                    .THREAD_ID(w * THREADS_PER_BLOCK + i),
                    .BLOCK_DIM(BLOCK_DIM)
                ) thread_regs (
                    .clk(clk),
                    .reset(reset),
                    .enable(1'b1),
                    .block_id(block_id),
                    .core_state(core_state),
                    .thread_active(active_mask[w][i]),
                    .warp_active(warp_active_flag),

                    .decoded_rd_address(decoded_rd_address),
                    .decoded_rs_address(decoded_rs_address),
                    .decoded_rt_address(decoded_rt_address),

                    .decoded_reg_write_enable(decoded_reg_write_enable),
                    .decoded_reg_input_mux(decoded_reg_input_mux),
                    .decoded_id_read(decoded_id_read),
                    .decoded_immediate(decoded_immediate),

                    .alu_out(active_alu_out[i]), // Fed from the shared ALU!
                    .lsu_out(lsu_out_bus[w][i]),

                    .rs(rs_bus[w][i]),
                    .rt(rt_bus[w][i]),

                    .mac_result(mac_or_fc_result),
                    .debug_reg3(reg3_bus[w][i])
                );

                lsu #(.ADDR_BITS(ADDR_BITS)) thread_lsu (
                    .clk(clk),
                    .reset(reset),
                    .enable(1'b1),
                    .thread_active(active_mask[w][i]),
                    .warp_active(warp_active_flag),
                    .core_state(core_state),

                    .decoded_mem_read(decoded_mem_read_enable),
                    .decoded_mem_write(decoded_mem_write_enable),
                    .decoded_base_add(decoded_base_add),
                    .decoded_wbase_add(decoded_wbase_add),
                    .decoded_immediate(decoded_immediate),

                    .rs(rs_bus[w][i]),
                    .rt(rt_bus[w][i]),

                    .mem_valid(lsu_mem_valid[w][i]),
                    .mem_addr(lsu_mem_addr[w][i]),
                    .mem_write_data(lsu_mem_write_data[w][i]),
                    .mem_ready(arb_ready[flat_id]),
                    .mem_read_data(arb_rdata[flat_id]),

                    .mem_we(lsu_we[w][i]),
                    .mem_waddr(lsu_waddr[w][i]),
                    .mem_wdata(lsu_wdata[w][i]),

                    .emit_valid(lsu_emit_valid[w][i]),
                    .emit_data(lsu_emit_data[w][i]),
                    // Only the warp that currently owns the UART sees the ack.
                    .emit_ready((emit_owned && emit_owner == w) ? emit_ready : 1'b0),

                    .lsu_state(lsu_states[w][i]),
                    .lsu_out(lsu_out_bus[w][i])
                );

                // Tie Arbiter flattened arrays
                assign lsu_req[flat_id] = lsu_mem_valid[w][i];
                assign lsu_addr[flat_id] = lsu_mem_addr[w][i];

                pc thread_pc (
                    .clk(clk),
                    .reset(reset),
                    .enable(1'b1),
                    .warp_active(warp_active_flag),
                    .core_state(core_state),

                    .decoded_nzp(decoded_nzp),
                    .decoded_immediate(decoded_immediate),
                    .decoded_nzp_write_enable(decoded_nzp_write_enable),
                    .decoded_pc_mux(decoded_pc_mux),

                    .alu_out(active_alu_out[i]),
                    .branch_taken(all_branch_votes[w][i]),

                    .current_pc(pc_bus[w][i]),
                    .next_pc(next_pc_bus[w][i])
                );

                assign pc_bus[w][i] = next_pc_bus[w][i];
            end
        end
    endgenerate

endmodule