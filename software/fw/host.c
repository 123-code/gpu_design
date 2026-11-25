// Host-CPU firmware (src/host_cpu.sv): drive the GPU with no PC attached.
//
//   1. copy the kernel (host_kernel.asm, assembled into kernel.c) into the
//      GPU's instruction memory
//   2. write 8 input halfwords into global memory (the SDRAM the GPU reads)
//   3. launch a grid of 2 blocks and wait for it
//   4. read the GPU's results back out of global memory, check them, and
//      send them over the UART, then 'P' (all right) or 'F'
//
// rv32i has no multiply instruction; clang calls __mulsi3 (defined below).
#include <stdint.h>

#define GPU_IMEM   ((volatile uint32_t *)0x10000000)   // word i = instruction i
#define GMEM16     ((volatile uint16_t *)0x20000000)   // global memory, halfwords
#define GPU_CTRL   (*(volatile uint32_t *)0x30000000)  // w: launch (gridDim), r: bit 0 idle
#define UART_TX    (*(volatile uint32_t *)0x30000004)  // w: send a byte (blocks)

extern const uint16_t kernel[];
extern const int kernel_len;

unsigned __mulsi3(unsigned a, unsigned b) {
    unsigned r = 0;
    while (b) { if (b & 1) r += a; a <<= 1; b >>= 1; }
    return r;
}

static uint16_t input(int i) { return (uint16_t)(37 * i + 5); }

int main(void) {
    for (int i = 0; i < kernel_len; i++) GPU_IMEM[i] = kernel[i];
    for (int i = 0; i < 8; i++) GMEM16[i] = input(i);

    GPU_CTRL = 2;                          // launch: 2 blocks
    while (!(GPU_CTRL & 1)) ;              // wait for the grid

    int ok = 1;
    for (int i = 0; i < 8; i++) {
        uint16_t x = input(i);
        uint16_t want = (uint16_t)(x * x + (i >> 2));   // block = i / 4
        uint16_t got = GMEM16[32 + i];
        if (got != want) ok = 0;
        UART_TX = got & 0xff;
    }
    UART_TX = ok ? 'P' : 'F';
    return 0;
}
