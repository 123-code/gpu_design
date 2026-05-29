// Timing constraint for the Tang Nano 20K 27 MHz system clock.
// 27 MHz -> 37.037 ns period. This lets the tool verify the design closes timing.
create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]
