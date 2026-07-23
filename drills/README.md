# Verilog interview drills

You do not need to "learn Verilog" by Tuesday. You need ~10 constructs and the
muscle memory to type five small modules cold. That surface is covered by
`CHEATSHEET.md` (one page — read it once, then only as a reference) and these
six drills.

## How to drill

```
make drill D=01_counter        # compile your attempt + run the checker
make drill-peek D=01_counter   # run the reference solution instead
```

Each `drills/NN_name.sv` has the ports declared and an empty body. The
testbench prints `PASS` or tells you exactly which check failed.

The loop that works (deliberate practice, not reading):

1. Attempt cold. 15 minutes max.
2. Stuck or failing? Read the solution in `solutions/`. Understand every line.
3. **Delete your attempt and retype the module from memory.** This step is the
   drill. Reading a solution teaches nothing; reproducing it does.
4. A drill counts as done when you've typed it from a blank body to PASS
   twice, on different days.

## Order and pacing (Sat + Sun, ~2h/day)

| Drill | Teaches | Interview frequency |
|---|---|---|
| 01_counter | always_ff, sync reset, enable | warm-up |
| 02_edge | remembering last cycle's value | very high |
| 03_alu | always_comb, case, latch trap | high |
| 04_shift | concatenation | medium |
| 05_fsm | THE classic FSM screen | **near-certain** |
| 06_fifo | pointers + count, design thinking | high (senior-flavored) |

If you only have time for three: 01, 03, 05.

Do them in `drills/NN_name.sv` directly — the sim binaries (`drills/sim_*`)
are throwaway.
