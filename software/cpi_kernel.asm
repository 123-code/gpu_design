// Issue-rate microbenchmark (test/tb_cpi.sv): a compute-only loop, no memory.
// 50 iterations x 4 instructions + setup. The testbench counts instructions
// (DECODE entries) and cycles from start to done on core 0.
        MOV  R1, #0
        MOV  R2, #50
        MOV  R3, #1
        MOV  R4, #0
loop:   ADD  R1, R1, R3
        ADD  R4, R4, R1
        CMP  R1, R2
        BRn  loop
        RET
