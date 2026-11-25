# Gowin techmap files from yosys 0.71

`brams_nodp.txt` is yosys 0.71's `share/gowin/brams.txt` with the
true-dual-port `$__GOWIN_DP_` block removed: nextpnr-himbaechel cannot place
DP, and every memory here has one write and one read port, which SDP covers.
`oss_build/build_board.sh` maps memories with it.

`cells_map.v` is 0.71's `share/gowin/cells_map.v`, unchanged. It is only used
by build_board.sh's split flow (`Y71=...`), where an older system yosys runs
ABC on a netlist yosys 0.71 produced and must finish it with the same cell
mapping (older versions emit cell names nextpnr rejects).

yosys is ISC-licensed, Copyright (C) Claire Xenia Wolf and contributors.
