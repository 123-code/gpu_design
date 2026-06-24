`default_nettype none
`timescale 1ns/1ns

// 27 MHz crystal -> 54 MHz system clock via the Gowin rPLL hard block.
//   CLKOUT = CLKIN * (FBDIV_SEL+1)/(IDIV_SEL+1) = 27 * 2/1 = 54 MHz
//   VCO    = CLKOUT * ODIV_SEL = 54 * 16 = 864 MHz (within the GW2A range)
//
// The rPLL is an FPGA hard macro that does not exist in simulation, so it is
// compiled in only under `SYNTH (the open-source build passes sv2v -DSYNTH).
// In simulation this module is a transparent pass-through, so the testbenches'
// own clock drives the design unchanged.
module gowin_pll (
    input  wire clkin,
    output wire clkout,
    output wire lock
);
`ifdef PLL_BYPASS_DIAG
    assign clkout = clkin;     // DIAGNOSTIC: run straight off the 27 MHz crystal
    assign lock   = 1'b1;
`elsif SYNTH
    // rPLL: 27 MHz crystal -> 135 MHz system clock. Verified working on the
    // GW2AR-18C (Tang Nano 20K); plain rPLL is correct here, no PLLVR needed.
    // (apicula can't pack PLLVR for this device anyway.) -DPLL_BYPASS_DIAG forces
    // 27 MHz (no PLL).
    //   CLKOUT = CLKIN * (FBDIV_SEL+1)/(IDIV_SEL+1) = 27 * 3/1 = 81 MHz
    //   VCO    = CLKOUT * ODIV_SEL = 81 * 8 = 648 MHz (within GW2A range)
    // 81 MHz = 27x3 is the proven-good clock on this board. Higher rPLL steps were
    // tried after the reset fix lifted STA Fmax to ~140: 27x4 = 108 MHz and
    // 27x5 = 135 MHz BOTH pass static timing but produce garbage / no UART on real
    // HW (this device's rPLL is fragile above 81 — see memory/pll-54mhz-bringup.md).
    // Stay at 81; ops/s is raised via the scheduler FSM trim instead, not the clock.
    rPLL #(
        .FCLKIN("27"),
        .IDIV_SEL(0),          // input divider  /1
        .FBDIV_SEL(2),         // feedback divider x3  -> 81 MHz out
        .ODIV_SEL(8),          // VCO = 81*8 = 648 MHz
        .DYN_IDIV_SEL("false"),
        .DYN_FBDIV_SEL("false"),
        .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"),
        .DYN_DA_EN("false"),
        .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1),
        .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0),
        .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW2A-18C")
    ) u_rpll (
        .CLKOUT(clkout),
        .LOCK(lock),
        .CLKOUTP(),
        .CLKOUTD(),
        .CLKOUTD3(),
        .RESET(1'b0),
        .RESET_P(1'b0),
        .CLKIN(clkin),
        .CLKFB(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .ODSEL(6'b0),
        .PSDA(4'b0),
        .DUTYDA(4'b0),
        .FDLY(4'b0)
    );
`else
    assign clkout = clkin;     // simulation: pass the testbench clock straight through
    assign lock   = 1'b1;
`endif
endmodule
