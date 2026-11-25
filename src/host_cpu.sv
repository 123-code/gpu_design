`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// On-chip host CPU: a small RV32I core (the Grace in GB200, at this scale).
//
// On a GB200 the CPU sits next to the GPUs and shares one memory space with
// them over NVLink-C2C, so it can hand a GPU work and read its results without
// a PCIe hop. Here the CPU sits next to the GPU on the same die and reaches
// the same global memory (SDRAM) through the same arbiter the GPU cores use:
// it writes inputs, writes the kernel into the GPU's instruction memory,
// launches a grid, waits, and reads the results back, with no host PC
// involved. Its firmware is C, built with clang for rv32i (software/fw/).
//
// Multi-cycle, no pipeline, no cache: FETCH -> EXEC -> (MEM) -> back. All of
// RV32I except FENCE/ECALL/EBREAK/CSR (FENCE runs as a no-op; ECALL/EBREAK
// halt). Local RAM (firmware, data, stack) at 0; everything else is a stall-
// until-ack bus the top level decodes (see top.sv for the map).
// ============================================================================
module host_cpu #(
    parameter RAM_WORDS = 1024,                 // 4 KB
    parameter FIRMWARE  = "software/build/fw.hex"
) (
    input  wire        clk,
    input  wire        reset,

    output reg         bus_req,
    output reg         bus_we,
    output reg  [31:0] bus_addr,
    output reg  [31:0] bus_wdata,
    output reg  [3:0]  bus_wbe,
    input  wire        bus_ack,                 // 1-cycle: write done / read data valid
    input  wire [31:0] bus_rdata,

    output reg         halted
);
    localparam AW = $clog2(RAM_WORDS);

    reg [31:0] ram [0:RAM_WORDS-1];
    initial $readmemh(FIRMWARE, ram);

    reg  [31:0] x [0:31];
    reg  [31:0] pc;
    reg  [31:0] ir;
    reg  [31:0] ram_rdata;
    reg  [AW-1:0] ram_raddr;
    reg         ram_we;
    reg  [AW-1:0] ram_waddr;
    reg  [31:0] ram_wdata;
    reg  [3:0]  ram_wbe;

    always @(posedge clk) begin
        if (ram_we) begin
            if (ram_wbe[0]) ram[ram_waddr][7:0]   <= ram_wdata[7:0];
            if (ram_wbe[1]) ram[ram_waddr][15:8]  <= ram_wdata[15:8];
            if (ram_wbe[2]) ram[ram_waddr][23:16] <= ram_wdata[23:16];
            if (ram_wbe[3]) ram[ram_waddr][31:24] <= ram_wdata[31:24];
        end
        ram_rdata <= ram[ram_raddr];
    end

    // ---------------- decode ----------------
    wire [6:0]  opc = ir[6:0];
    wire [4:0]  rd  = ir[11:7];
    wire [2:0]  f3  = ir[14:12];
    wire [4:0]  rs1 = ir[19:15];
    wire [4:0]  rs2 = ir[24:20];
    wire [6:0]  f7  = ir[31:25];
    wire [31:0] v1  = (rs1 == 5'd0) ? 32'd0 : x[rs1];
    wire [31:0] v2  = (rs2 == 5'd0) ? 32'd0 : x[rs2];
    wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
    wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
    wire [31:0] imm_b = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
    wire [31:0] imm_u = {ir[31:12], 12'd0};
    wire [31:0] imm_j = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};

    // ALU (OP and OP-IMM)
    wire        is_op  = (opc == 7'b0110011);
    wire [31:0] b_in   = is_op ? v2 : imm_i;
    wire [4:0]  shamt  = b_in[4:0];
    reg  [31:0] alu;
    always @(*) begin
        case (f3)
            3'd0: alu = (is_op && f7[5]) ? v1 - b_in : v1 + b_in;
            3'd1: alu = v1 << shamt;
            3'd2: alu = ($signed(v1) < $signed(b_in)) ? 32'd1 : 32'd0;
            3'd3: alu = (v1 < b_in) ? 32'd1 : 32'd0;
            3'd4: alu = v1 ^ b_in;
            3'd5: alu = f7[5] ? $signed(v1) >>> shamt : v1 >> shamt;
            3'd6: alu = v1 | b_in;
            default: alu = v1 & b_in;
        endcase
    end

    reg take;
    always @(*) begin
        case (f3)
            3'd0: take = (v1 == v2);
            3'd1: take = (v1 != v2);
            3'd4: take = ($signed(v1) <  $signed(v2));
            3'd5: take = ($signed(v1) >= $signed(v2));
            3'd6: take = (v1 <  v2);
            3'd7: take = (v1 >= v2);
            default: take = 1'b0;
        endcase
    end

    // load/store address and lane placement
    wire [31:0] ls_addr = v1 + ((opc == 7'b0100011) ? imm_s : imm_i);
    wire        ls_local = (ls_addr < RAM_WORDS * 4);
    wire [3:0]  st_be = (f3[1:0] == 2'd0) ? (4'b0001 << ls_addr[1:0])
                      : (f3[1:0] == 2'd1) ? (ls_addr[1] ? 4'b1100 : 4'b0011)
                      :                     4'b1111;
    wire [31:0] st_data = (f3[1:0] == 2'd0) ? {4{v2[7:0]}}
                        : (f3[1:0] == 2'd1) ? {2{v2[15:0]}}
                        :                     v2;

    function [31:0] load_ext(input [31:0] w, input [2:0] f, input [1:0] a);
        reg [7:0]  b;
        reg [15:0] h;
        begin
            b = w[8*a +: 8];
            h = a[1] ? w[31:16] : w[15:0];
            case (f)
                3'd0: load_ext = {{24{b[7]}}, b};
                3'd1: load_ext = {{16{h[15]}}, h};
                3'd4: load_ext = {24'd0, b};
                3'd5: load_ext = {16'd0, h};
                default: load_ext = w;
            endcase
        end
    endfunction

    // FETCH: address the RAM; FWAIT: RAM samples it; IR: latch the word;
    // EXEC: everything else (loads/stores add LOAD+LOADW or BUS)
    localparam S_FETCH = 3'd0, S_FWAIT = 3'd1, S_EXEC = 3'd2, S_LOAD = 3'd3,
               S_BUS = 3'd4, S_HALT = 3'd5, S_IR = 3'd6, S_LOADW = 3'd7;
    reg [2:0]  state;
    reg [31:0] ld_addr;

    integer i;
    always @(posedge clk) begin
        if (reset) begin
            state   <= S_FETCH;
            pc      <= 32'd0;
            bus_req <= 1'b0;
            ram_we  <= 1'b0;
            halted  <= 1'b0;
            ir      <= 32'h00000013;           // nop
            for (i = 0; i < 32; i = i + 1) x[i] <= 32'd0;
        end else begin
            ram_we <= 1'b0;
            case (state)
                S_FETCH: begin
                    ram_raddr <= pc[AW+1:2];
                    state     <= S_FWAIT;
                end
                S_FWAIT: state <= S_IR;                 // RAM read latency
                S_IR: begin
                    ir    <= ram_rdata;
                    state <= S_EXEC;
                end
                S_EXEC: begin
                    pc    <= pc + 32'd4;
                    state <= S_FETCH;
                    case (opc)
                        7'b0110111: x[rd] <= imm_u;                       // LUI
                        7'b0010111: x[rd] <= pc + imm_u;                  // AUIPC
                        7'b1101111: begin x[rd] <= pc + 32'd4; pc <= pc + imm_j; end   // JAL
                        7'b1100111: begin x[rd] <= pc + 32'd4; pc <= (v1 + imm_i) & ~32'd1; end // JALR
                        7'b1100011: if (take) pc <= pc + imm_b;           // branches
                        7'b0010011, 7'b0110011: x[rd] <= alu;             // OP-IMM / OP
                        7'b0000011: begin                                 // loads
                            ld_addr <= ls_addr;
                            if (ls_local) begin
                                ram_raddr <= ls_addr[AW+1:2];
                                state     <= S_LOAD;
                            end else begin
                                bus_req   <= 1'b1;
                                bus_we    <= 1'b0;
                                bus_addr  <= ls_addr;
                                state     <= S_BUS;
                            end
                        end
                        7'b0100011: begin                                 // stores
                            if (ls_local) begin
                                ram_we    <= 1'b1;
                                ram_waddr <= ls_addr[AW+1:2];
                                ram_wdata <= st_data;
                                ram_wbe   <= st_be;
                            end else begin
                                bus_req   <= 1'b1;
                                bus_we    <= 1'b1;
                                bus_addr  <= ls_addr;
                                bus_wdata <= st_data;
                                bus_wbe   <= st_be;
                                state     <= S_BUS;
                            end
                        end
                        7'b0001111: ;                                     // FENCE: no-op
                        7'b1110011: begin halted <= 1'b1; state <= S_HALT; end  // ECALL/EBREAK
                        default: begin halted <= 1'b1; state <= S_HALT; end     // illegal
                    endcase
                end
                S_LOAD: state <= S_LOADW;
                S_LOADW: begin
                    if (rd != 5'd0) x[rd] <= load_ext(ram_rdata, f3, ld_addr[1:0]);
                    state <= S_FETCH;
                end
                S_BUS: if (bus_ack) begin
                    bus_req <= 1'b0;
                    if (!bus_we && rd != 5'd0) x[rd] <= load_ext(bus_rdata, f3, ld_addr[1:0]);
                    state <= S_FETCH;
                end
                S_HALT: ;
                default: state <= S_FETCH;
            endcase
            x[0] <= 32'd0;
        end
    end
endmodule
