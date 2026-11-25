# Host CPU reset entry: stack at the top of the 4 KB RAM, call main, halt.
    .section .text.start
    .globl _start
_start:
    li   sp, 0x1000
    call main
1:  ebreak
    j    1b
