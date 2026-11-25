// Feature switches off, for `make sim-subset`: compiled alongside a
// testbench whose `top` instance is tb.dut, so the reduced configuration a
// board build would use is exercised by the same tests (`-s cfg`).
module cfg;
    defparam tb.dut.TC_ENABLE   = 0;
    defparam tb.dut.TMA_ENABLE  = 0;
    defparam tb.dut.GMEM_ENABLE = 0;
    defparam tb.dut.LINK_ENABLE = 0;
endmodule
