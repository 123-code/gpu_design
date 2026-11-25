/* Host CPU firmware: everything in the 4 KB local RAM at address 0. */
MEMORY { RAM (rwx) : ORIGIN = 0, LENGTH = 4K }
SECTIONS {
  .text : { *(.text.start) *(.text*) } > RAM
  .rodata : { *(.rodata*) *(.srodata*) } > RAM
  .data : { *(.data*) *(.sdata*) } > RAM
  .bss : { *(.bss*) *(.sbss*) *(COMMON) } > RAM
}
