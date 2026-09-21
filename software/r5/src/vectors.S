/* R5 low vectors live in ATCM at address zero. Supplying _vector_table here
 * prevents the standalone BSP's non-RTOS vector object being linked. The BSP
 * still supplies _boot, mode stacks, MPU setup and C runtime initialization. */
.arm
.section .vectors,"ax"
.balign 32
.global _vector_table
.global _freertos_vector_table
_vector_table:
_freertos_vector_table:
 ldr pc, =_boot
 ldr pc, =r5_fault_handler
 ldr pc, =FreeRTOS_SWI_Handler
 ldr pc, =r5_fault_handler
 ldr pc, =r5_fault_handler
 nop
 ldr pc, =FreeRTOS_IRQ_Handler
 ldr pc, =r5_fault_handler
.text
.balign 4
.global r5_fault_handler
.type r5_fault_handler, %function
r5_fault_handler:
 cpsid if
1: wfi
 b 1b
.global _init
.type _init, %function
_init:
 bx lr
.global _fini
.type _fini, %function
_fini:
 bx lr
