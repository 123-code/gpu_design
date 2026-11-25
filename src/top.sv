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
    // sys_clk frequency for UART bit timing. Must match the ACTUAL clock:
    //   normal build (rPLL)            -> 81 MHz  (theoretical max, 27x3)
    //   -DPLL_BYPASS_DIAG (no PLL)     -> 27 MHz, straight off the crystal
    // NOTE: uart_tx.clock_count must be wide enough to hold CLK_FREQ/BAUD_RATE
    // (703 at 81 MHz) — it is [15:0]. Override CLK_FREQ in sim.
`ifdef PLL_BYPASS_DIAG
    parameter CLK_FREQ      = 27000000,
`else
    parameter CLK_FREQ      = 54000000,    // rPLL 27x2 (see gowin_pll.sv); must match FBDIV
`endif
    parameter BAUD_RATE     = 115200, //baud rate
    parameter BLOCK_DIM     = 8,         // launch size: threads per block (warps x TPB lanes)
    parameter THREADS_PER_BLOCK = 4,     // warp width = physical ALU lanes per core
    parameter WARPS_PER_CORE = 2,        // warps/core (1 = no latency hiding, max compute/LUT)
    // SDRAM: 200 us power-up wait at 54 MHz, refresh well inside 15.6 us.
    // Testbenches shrink the wait.
    parameter SDRAM_INIT_CYCLES = 10800,
    parameter SDRAM_REF_CYCLES  = 750,
    // On-chip host CPU (host_cpu.sv): 0 = none, the PC is the host (default)
    parameter HOST_CPU = 0,
    parameter FIRMWARE = "software/build/fw.hex",
    // Board link (board_link.sv): system clocks per link bit
    parameter LINK_DIV = 4,
    // Feature switches for a board build (docs/blackwell.md "Board fit").
    // GMEM_ENABLE=0 drops the SDRAM controller, its arbiter, the cores' L1s
    // and the link (the host CPU needs global memory too).
    parameter TC_ENABLE   = 1,
    parameter TC_KINDS    = 5'b11111,
    parameter TMA_ENABLE  = 1,
    parameter GMEM_ENABLE = 1,
    parameter LINK_ENABLE = 1
) (
    input  wire       clk,          // 27 MHz crystal  (PIN 4)
    input  wire       uart_rx_in,    // from host       (PIN 70)
    output wire       uart_tx_out,   // to host         (PIN 69)
    output wire [5:0] led,           // leds to show result on them
    output wire       tmds_clk_p,    // HDMI            (PINs 33-40)
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
    // Optional ports. A board build that leaves the board link or global
    // memory out defines NO_LINK_PORTS / NO_SDRAM_PORTS, and the ports
    // become internal wires: no pins, nothing for gpu.cst to constrain.
`ifndef NO_LINK_PORTS
    // Board-to-board link (two GPIO wires to the other board; NVLink in
    // miniature). Pins: src/gpu_link.cst.
    , output wire      link_tx
`ifdef SYNTH
    , input  wire      link_rx      // board: PULL_MODE=UP (src/gpu_link.cst)
`else
    , input  tri1      link_rx      // sim: idles high when no board is attached
`endif
`endif
`ifndef NO_SDRAM_PORTS
    // In-package SDRAM (GW2AR-18: 64 Mbit, 2M x 32). The names are the ones
    // the Tang Nano 20K examples use for the die's embedded SDRAM; they are
    // internal to the package, so they take no IO_LOC (src/gpu_sdram.cst).
    , output wire        O_sdram_clk
    , output wire        O_sdram_cke
    , output wire        O_sdram_cs_n
    , output wire        O_sdram_cas_n
    , output wire        O_sdram_ras_n
    , output wire        O_sdram_wen_n
    , output wire [3:0]  O_sdram_dqm
    , output wire [10:0] O_sdram_addr
    , output wire [1:0]  O_sdram_ba
    , inout  wire [31:0] IO_sdram_dq
`endif
);
`ifdef NO_LINK_PORTS
    wire link_tx;
    wire link_rx = 1'b1;
`endif
`ifdef NO_SDRAM_PORTS
    wire O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n;
    wire [3:0]  O_sdram_dqm;
    wire [10:0] O_sdram_addr;
    wire [1:0]  O_sdram_ba;
    wire [31:0] IO_sdram_dq;
`endif
    // ---- system clock: 27 MHz crystal pin -> 54 MHz via the rPLL ----
    // (gowin_pll is a transparent pass-through in simulation, so tbs drive sys_clk
    // with their own clk and CLK_FREQ.) Everything below runs on sys_clk.
    wire sys_clk;
    wire pll_lock;
    gowin_pll u_pll (.clkin(clk), .clkout(sys_clk), .lock(pll_lock));

    // ---- system power-on reset: held until the PLL locks AND the POR counter fills ----
    reg [3:0] por = 4'd0; //forcing the counter to wake up at 0
    wire por_done = &por;
    always @(posedge sys_clk) if (!por_done) por <= por + 1'b1;
    // sys_reset is high (everything frozen) until the clock is stable (lock) and POR done.
    wire sys_reset = !por_done || !pll_lock;

    // ---- Host-to-Device pipeline ----
    wire [7:0]  grid_dim;             // blocks in the launch (frame header)
    wire        cluster;              // cluster launch (frame header)
    // The run's launch config: from the frame header, or from the host CPU
    // when it launched the run
    reg         cpu_owns = 1'b0;
    reg  [7:0]  cpu_grid = 8'd0;
    reg         cpu_cluster = 1'b0;
    wire [7:0]  run_grid    = cpu_owns ? cpu_grid    : grid_dim;
    wire        run_cluster = cpu_owns ? cpu_cluster : cluster;
    // host CPU -> GPU instruction memory and launch
    wire        cpu_iwe;
    wire [7:0]  cpu_iaddr;
    wire [15:0] cpu_idata;
    wire        cpu_launch;
    wire        dma_g_we;             // a payload byte for global memory
    wire [12:0] dma_g_addr;
    wire [7:0]  dma_g_data;
    // global-memory clients: 0 = core 0, 1 = core 1, 2 = DMA, 3 = host CPU,
    // 4 = stores arriving over the board link
    wire [4:0]  g_req, g_we_c, g_ack, g_rvalid, g_done;
    wire [20:0] g_addr_c  [4:0];
    wire [31:0] g_wdata_c [4:0];
    wire [3:0]  g_wbe_c   [4:0];
    // the cores' side of their link routers
    wire [1:0]  cg_req, cg_ack, cg_rvalid, cg_done;
    wire [31:0] cg_rdata [1:0];
    wire [31:0] sd_rdata;
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
    wire        gpu_done_raw;         // the GPU's own done; `done` also waits for the board link
    wire        link_idle;
    wire [7:0]  result;               //predicted (in this case 8 bits because it is a digit)

    data_pipeline #(
        .ADDR_BITS(13),
        .PAYLOAD_BYTES(PAYLOAD_BYTES),
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) pipe (
        .clk(sys_clk), .reset(sys_reset),
        .uart_rx_in(uart_rx_in),
        .gpu_done(done),              // GPU done -> DMA re-arms for next frame
        .gpu_start(gpu_start),
        .loading(loading),
        .grid_dim(grid_dim),
        .cluster(cluster),
        .dma_g_we(dma_g_we),
        .dma_g_addr(dma_g_addr),
        .dma_g_data(dma_g_data),
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
    always @(posedge sys_clk) begin
        if (sys_reset)        begin armed <= 1'b0; runrst <= 5'd0; end
        //if gpu start, we set the armed register to 1 and the runrst counter to 0
        else if (gpu_start || cpu_launch) begin armed <= 1'b1; runrst <= 5'd0; end // new run
        else if (armed && !(&runrst)) runrst <= runrst + 1'b1;
    end
    // Register the GPU reset. gpu_reset fans out to every flop in the design, so
    // driving it from combinational logic (sys_reset || !armed || ...) put a long
    // high-fanout combinational net on the critical path (POR/pll-lock gate ->
    // wide-accumulator CLEAR pins). Registering it makes the fanned-out net a
    // clean FF source with the whole clock period to propagate; the extra cycle of
    // reset-deassert latency is harmless (the run already waits out POR + runrst).
    reg gpu_reset_r = 1'b1;
    always @(posedge sys_clk)
        gpu_reset_r <= sys_reset || !armed || !(&runrst);
    wire gpu_reset  = gpu_reset_r;
    wire gpu_enable = armed && (&runrst); //on when job armed, startup countdown finished

    // ---- the GPU ----
    wire       emit_valid;//valid data to be sent out 
    wire [7:0] emit_data;//byte ti send
    reg        emit_ready;//ready to send out data
//ports open to the gpu, ehich contsins dispatecer, program memory,compute cores
    gpu #(.BLOCK_DIM(BLOCK_DIM), .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
          .WARPS_PER_CORE(WARPS_PER_CORE),
          .TC_ENABLE(TC_ENABLE), .TC_KINDS(TC_KINDS), .TMA_ENABLE(TMA_ENABLE),
          .GMEM_ENABLE(GMEM_ENABLE)) uut (
        .clk(sys_clk),
        .reset(gpu_reset),
        .enable(gpu_enable),
        .grid_dim(run_grid),
        .cluster(run_cluster),
        .result(result),
        .done(gpu_done_raw),
        .debug_core_state(),
        .debug_instruction(),
        .operand_a(6'd0),             // operand-injection unused in host-driven mode
        .operand_b(6'd0),
        .instr_we(instr_we || cpu_iwe),
        .instr_waddr(cpu_iwe ? cpu_iaddr : instr_waddr),
        .instr_wdata(cpu_iwe ? cpu_idata : instr_wdata),
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
        .g0_req(cg_req[0]), .g0_we(g_we_c[0]), .g0_addr(g_addr_c[0]), .g0_wdata(g_wdata_c[0]),
        .g0_wbe(g_wbe_c[0]), .g0_ack(cg_ack[0]), .g0_rvalid(cg_rvalid[0]), .g0_rdata(cg_rdata[0]),
        .g0_done(cg_done[0]),
        .g1_req(cg_req[1]), .g1_we(g_we_c[1]), .g1_addr(g_addr_c[1]), .g1_wdata(g_wdata_c[1]),
        .g1_wbe(g_wbe_c[1]), .g1_ack(cg_ack[1]), .g1_rvalid(cg_rvalid[1]), .g1_rdata(cg_rdata[1]),
        .g1_done(cg_done[1]),
        .emit_valid(emit_valid),
        .emit_data(emit_data),
        .emit_ready(emit_ready)
    );

    // ---- global memory: the in-package SDRAM, shared by both cores and the host ----
    // Clients: core 0, core 1 (each already muxing its L1 and copy engine),
    // and the DMA writing a global payload. Round-robin, one op at a time.
    wire        sd_req, sd_we, sd_ack, sd_rvalid, sd_done, sd_init_done;
    wire [20:0] sd_addr;
    wire [31:0] sd_wdata;
    wire [3:0]  sd_wbe;

    // DMA byte -> one masked word write (bytes arrive far slower than a write takes)
    reg        dg_req = 1'b0;
    reg [12:0] dg_addr;
    reg [7:0]  dg_data;
    always @(posedge sys_clk) begin
        if (sys_reset) dg_req <= 1'b0;
        else if (dma_g_we) begin
            dg_req <= 1'b1; dg_addr <= dma_g_addr; dg_data <= dma_g_data;
        end else if (g_ack[2]) dg_req <= 1'b0;
    end
    assign g_req[2]     = dg_req;
    assign g_we_c[2]    = 1'b1;
    assign g_addr_c[2]  = {10'd0, dg_addr[12:2]};
    assign g_wdata_c[2] = {4{dg_data}};
    assign g_wbe_c[2]   = 4'b0001 << dg_addr[1:0];

    // ---- board link: each core's global port goes through a router that
    //      sends stores to bit-15 addresses to the other board ----
    wire [1:0]  lk_req, lk_ack;
    wire [15:0] lk_addr [1:0];
    wire [15:0] lk_data [1:0];
    wire [15:0] lk_link_sent, lk_link_received;
    genvar gl;
    generate if (LINK_ENABLE && GMEM_ENABLE) begin : linkg
    for (gl = 0; gl < 2; gl = gl + 1) begin : routers
        link_router u_rt (
            .clk(sys_clk), .reset(sys_reset),
            .c_req(cg_req[gl]), .c_we(g_we_c[gl]), .c_addr(g_addr_c[gl]),
            .c_wdata(g_wdata_c[gl]), .c_wbe(g_wbe_c[gl]),
            .c_ack(cg_ack[gl]), .c_rvalid(cg_rvalid[gl]), .c_done(cg_done[gl]), .c_rdata(cg_rdata[gl]),
            .a_req(g_req[gl]), .a_ack(g_ack[gl]), .a_rvalid(g_rvalid[gl]), .a_done(g_done[gl]),
            .a_rdata(sd_rdata),
            .l_req(lk_req[gl]), .l_addr(lk_addr[gl]), .l_data(lk_data[gl]), .l_ack(lk_ack[gl])
        );
    end
    // one link, two cores: core 0 first
    wire        lk_s_ack;
    wire        lk_pick1 = !lk_req[0];
    assign lk_ack[0] = lk_s_ack && !lk_pick1;
    assign lk_ack[1] = lk_s_ack &&  lk_pick1;
    board_link #(.DIV(LINK_DIV)) u_link (
        .clk(sys_clk), .reset(sys_reset),
        .s_req(lk_req[0] || lk_req[1]),
        .s_addr(lk_pick1 ? lk_addr[1] : lk_addr[0]),
        .s_data(lk_pick1 ? lk_data[1] : lk_data[0]),
        .s_ack(lk_s_ack), .idle(link_idle),
        .r_req(g_req[4]), .r_addr(g_addr_c[4]), .r_wdata(g_wdata_c[4]), .r_wbe(g_wbe_c[4]),
        .r_ack(g_ack[4]), .r_done(g_done[4]),
        .link_tx(link_tx), .link_rx(link_rx),
        .sent(lk_link_sent), .received(lk_link_received)
    );
    assign g_we_c[4] = 1'b1;
    end else begin : nolink
        // no link: the cores' global ports go straight to the SDRAM arbiter
        for (gl = 0; gl < 2; gl = gl + 1) begin : passthru
            assign g_req[gl]     = cg_req[gl];
            assign cg_ack[gl]    = g_ack[gl];
            assign cg_rvalid[gl] = g_rvalid[gl];
            assign cg_done[gl]   = g_done[gl];
            assign cg_rdata[gl]  = sd_rdata;
        end
        assign link_tx = 1'b1; assign link_idle = 1'b1;
        assign g_req[4] = 1'b0; assign g_we_c[4] = 1'b1; assign g_addr_c[4] = 21'd0;
        assign g_wdata_c[4] = 32'd0; assign g_wbe_c[4] = 4'd0;
        assign lk_link_sent = 16'd0; assign lk_link_received = 16'd0;
    end endgenerate
    // A run is done once the GPU is and every remote store has left the board
    assign done = gpu_done_raw && link_idle;

    generate if (GMEM_ENABLE) begin : gmemg
    mem_arb #(.N(5)) u_garb (
        .clk(sys_clk), .reset(sys_reset),
        .c_req(g_req), .c_we(g_we_c),
        .c_addr_p({g_addr_c[4], g_addr_c[3], g_addr_c[2], g_addr_c[1], g_addr_c[0]}),
        .c_wdata_p({g_wdata_c[4], g_wdata_c[3], g_wdata_c[2], g_wdata_c[1], g_wdata_c[0]}),
        .c_wbe_p({g_wbe_c[4], g_wbe_c[3], g_wbe_c[2], g_wbe_c[1], g_wbe_c[0]}),
        .c_ack(g_ack), .c_rvalid(g_rvalid), .c_done(g_done),
        .m_req(sd_req), .m_we(sd_we), .m_addr(sd_addr), .m_wdata(sd_wdata), .m_wbe(sd_wbe),
        .m_ack(sd_ack), .m_rvalid(sd_rvalid), .m_done(sd_done)
    );

    sdram_ctrl #(.INIT_CYCLES(SDRAM_INIT_CYCLES), .REF_INTERVAL(SDRAM_REF_CYCLES)) u_sdram (
        .clk(sys_clk), .reset(sys_reset),
        .req(sd_req), .we(sd_we), .addr(sd_addr), .wdata(sd_wdata), .wbe(sd_wbe),
        .ack(sd_ack), .rvalid(sd_rvalid), .rdata(sd_rdata), .done(sd_done),
        .init_done(sd_init_done),
        .sdram_cke(O_sdram_cke), .sdram_cs_n(O_sdram_cs_n), .sdram_ras_n(O_sdram_ras_n),
        .sdram_cas_n(O_sdram_cas_n), .sdram_we_n(O_sdram_wen_n), .sdram_ba(O_sdram_ba),
        .sdram_addr(O_sdram_addr), .sdram_dqm(O_sdram_dqm), .sdram_dq(IO_sdram_dq)
    );
    end else begin : nogmem
        assign g_ack = 5'd0; assign g_rvalid = 5'd0; assign g_done = 5'd0;
        assign sd_rdata = 32'd0; assign sd_init_done = 1'b0;
        assign sd_req = 1'b0; assign sd_we = 1'b0; assign sd_addr = 21'd0;
        assign sd_wdata = 32'd0; assign sd_wbe = 4'd0;
        assign sd_ack = 1'b0; assign sd_rvalid = 1'b0; assign sd_done = 1'b0;
        // SDRAM pins idle (deselected)
        assign O_sdram_cke = 1'b0; assign O_sdram_cs_n = 1'b1; assign O_sdram_ras_n = 1'b1;
        assign O_sdram_cas_n = 1'b1; assign O_sdram_wen_n = 1'b1; assign O_sdram_ba = 2'd0;
        assign O_sdram_addr = 11'd0; assign O_sdram_dqm = 4'hf; assign IO_sdram_dq = 32'bz;
    end endgenerate
    // SDRAM clocked 180 degrees from the controller: commands launched on a
    // sys_clk edge are sampled mid-cycle, read data is sampled a half cycle
    // after the chip drives it.
    assign O_sdram_clk = ~sys_clk;

    // ---- on-chip host CPU (Grace, at this scale) ----
    // Bus map:  0x1000_0000 + 4i  GPU instruction word i (write)
    //           0x2000_0000 + a   global memory byte address a (SDRAM)
    //           0x3000_0000       w: launch a grid (bits 7:0 gridDim, bit 8
    //                                cluster); r: bit 0 = no run in flight
    //           0x3000_0004       w: send a byte on the UART (blocks till sent)
    wire        cpu_tx_req;           // CPU byte waiting for the UART
    wire [7:0]  cpu_tx_byte;
    reg         cpu_tx_done;          // UART finished the CPU's byte
    reg         cpu_tx_take;          // UART took the CPU's byte
    wire        cpu_halted;
    reg         cpu_running = 1'b0;   // a CPU-launched run is in flight
    reg         done_d = 1'b0;
    generate if (HOST_CPU) begin : host
        wire        b_req, b_we;
        wire [31:0] b_addr, b_wdata;
        wire [3:0]  b_wbe;
        reg         b_ack;
        reg  [31:0] b_rdata;
        host_cpu #(.FIRMWARE(FIRMWARE)) u_cpu (
            .clk(sys_clk), .reset(sys_reset),
            .bus_req(b_req), .bus_we(b_we), .bus_addr(b_addr), .bus_wdata(b_wdata),
            .bus_wbe(b_wbe), .bus_ack(b_ack), .bus_rdata(b_rdata), .halted(cpu_halted)
        );
        wire sel_imem = b_addr[31:28] == 4'h1;
        wire sel_gmem = b_addr[31:28] == 4'h2;
        wire sel_ctrl = b_addr[31:28] == 4'h3 && !b_addr[2];
        wire sel_uart = b_addr[31:28] == 4'h3 &&  b_addr[2];
        // The CPU holds b_req until it sees b_ack, then drops it for at least
        // the next fetch, so each bus op starts with a rising edge.
        reg  b_req_d, g_issued, tx_want;
        wire first = b_req && !b_req_d;
        assign cpu_iwe     = first && sel_imem && b_we;
        assign cpu_iaddr   = b_addr[9:2];
        assign cpu_idata   = b_wdata[15:0];
        assign cpu_launch  = first && sel_ctrl && b_we;
        assign cpu_tx_req  = tx_want;
        assign cpu_tx_byte = b_wdata[7:0];
        // global memory: client 3. Reads fetch the 4-word line and keep the
        // word asked for; writes are one masked word.
        assign g_req[3]     = b_req && sel_gmem && !g_issued;
        assign g_we_c[3]    = b_we;
        assign g_addr_c[3]  = b_we ? {1'b0, b_addr[21:2]} : {1'b0, b_addr[21:4], 2'b00};
        assign g_wdata_c[3] = b_wdata;
        assign g_wbe_c[3]   = b_wbe;
        reg [1:0] beat;
        always @(posedge sys_clk) begin
            if (sys_reset) begin
                b_ack <= 1'b0; b_req_d <= 1'b0; g_issued <= 1'b0; beat <= 2'd0; tx_want <= 1'b0;
            end else begin
                b_ack   <= 1'b0;
                b_req_d <= b_req;
                if (first && (sel_imem || sel_ctrl)) begin
                    b_ack   <= 1'b1;                           // one-cycle targets
                    b_rdata <= {31'd0, !cpu_running};
                end
                if (first && sel_uart && b_we) tx_want <= 1'b1;
                if (cpu_tx_take) tx_want <= 1'b0;
                if (cpu_tx_done) b_ack <= 1'b1;
                if (g_ack[3]) g_issued <= 1'b1;
                if (!b_req)   g_issued <= 1'b0;
                if (g_rvalid[3]) begin
                    if (beat == b_addr[3:2]) b_rdata <= sd_rdata;
                    beat <= beat + 2'd1;
                end
                if (g_done[3]) begin b_ack <= 1'b1; beat <= 2'd0; end
            end
        end
    end else begin : no_host
        assign cpu_iwe = 1'b0; assign cpu_iaddr = 8'd0; assign cpu_idata = 16'd0;
        assign cpu_launch = 1'b0; assign cpu_tx_req = 1'b0; assign cpu_tx_byte = 8'd0;
        assign cpu_halted = 1'b0;
        assign g_req[3] = 1'b0; assign g_we_c[3] = 1'b0; assign g_addr_c[3] = 21'd0;
        assign g_wdata_c[3] = 32'd0; assign g_wbe_c[3] = 4'd0;
    end endgenerate

    // who launched the current run, and whether it is still in flight
    always @(posedge sys_clk) begin
        done_d <= done;
        if (sys_reset) begin
            cpu_owns <= 1'b0; cpu_running <= 1'b0;
        end else if (cpu_launch) begin
            cpu_owns <= 1'b1; cpu_running <= 1'b1;
            cpu_grid <= host_launch_word[7:0]; cpu_cluster <= host_launch_word[8];
        end else begin
            if (gpu_start) cpu_owns <= 1'b0;                 // a UART frame took over
            if (done && !done_d) cpu_running <= 1'b0;        // the run finished
        end
    end
    wire [31:0] host_launch_word;
    generate if (HOST_CPU) begin : hlw
        assign host_launch_word = host.b_wdata;
    end else begin : nhlw
        assign host_launch_word = 32'd0;
    end endgenerate

//fsm,pulses tx_start once to start uart_txand waits while busy then pulses emit ready so gpu can send the next byte
    wire uart_busy;
    reg  tx_start;
    localparam E_IDLE = 2'd0, E_SEND = 2'd1, E_WAIT = 2'd2;
    reg [1:0] estate;
    reg       tx_from_cpu;            // the byte in flight is the host CPU's
    reg [7:0] tx_byte;
    always @(posedge sys_clk) begin
        if (sys_reset) begin
            estate <= E_IDLE; tx_start <= 1'b0; emit_ready <= 1'b0;
            cpu_tx_done <= 1'b0; tx_from_cpu <= 1'b0; tx_byte <= 8'd0; cpu_tx_take <= 1'b0;
        end else begin
            tx_start <= 1'b0; emit_ready <= 1'b0; cpu_tx_done <= 1'b0; cpu_tx_take <= 1'b0;
            case (estate)
                // !emit_ready: during the ack cycle the GPU hasn't dropped
                // emit_valid yet (its FSM is registered); launching then would
                // send every byte twice. GPU bytes go first; the host CPU's
                // byte goes when the GPU has none.
                E_IDLE: if (emit_valid && !uart_busy && !emit_ready) begin
                            tx_start <= 1'b1;            // launch emit_data
                            tx_byte  <= emit_data;
                            tx_from_cpu <= 1'b0;
                            estate   <= E_SEND;
                        end else if (cpu_tx_req && !uart_busy && !cpu_tx_take) begin
                            tx_start <= 1'b1;
                            cpu_tx_take <= 1'b1;
                            tx_byte  <= cpu_tx_byte;
                            tx_from_cpu <= 1'b1;
                            estate   <= E_SEND;
                        end
                E_SEND: if (uart_busy) estate <= E_WAIT; // byte started
                E_WAIT: if (!uart_busy) begin            // byte fully sent
                            if (tx_from_cpu) cpu_tx_done <= 1'b1;
                            else             emit_ready  <= 1'b1;   // ack the GPU's STR
                            estate     <= E_IDLE;
                        end
            endcase
        end
    end

    uart_tx #(.BAUD_LIMIT(CLK_FREQ / BAUD_RATE)) u_tx (
        .clk(sys_clk), .reset(sys_reset),
        .data_in(tx_byte), .tx_start(tx_start),
        .tx_out(uart_tx_out), .tx_busy(uart_busy)
    );

    // ---- HDMI: the raycaster's columns (raycast.jpp), read off the UART reply ----
    // 2 cores x 4 waves (raycast.jpp) x BLOCK_DIM threads = one byte per column.
    hdmi_columns #(.COLS(8 * BLOCK_DIM)) u_hdmi (
        .clk27(clk), .sys_clk(sys_clk),
        .run_start(gpu_start), .byte_valid(tx_start), .byte_data(tx_byte),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    // ---- LEDs: loading status + done + low nibble of the result ----
    assign led = ~{loading, done, result[3:0]};

endmodule
