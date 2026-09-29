/* SPDX-License-Identifier: MIT
 * BL33 shim for volatile JTAG boot, entered at EL2 by TF-A.
 * FSBL initializes DDR; TF-A supplies PSCI, timer and execution state.
 * Addresses are checked by prepare.py. No stack, MMIO, or peripheral probing.
 */
.section .text
.global _start
_start:
    mov x0, #0x04000000              // DTB
    mov x1, xzr
    mov x2, xzr
    mov x3, xzr
    mov x4, #0x00200000              // uncompressed Image, text_offset == 0
    dsb sy
    ic iallu
    dsb sy
    isb
    br x4
