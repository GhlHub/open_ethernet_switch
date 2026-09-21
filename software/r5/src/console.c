/* UART1 console plus an always-available RAM log for early/fault diagnostics. */
#include <stdint.h>
#include <stdbool.h>
#include "board.h"
#include "xuartps.h"
#include "xuartps_hw.h"
#include "bspconfig.h"
#include "xparameters.h"
#define CONSOLE_BASE 0xff010000UL
#if !defined(XPAR_UART1_BASEADDR) || XPAR_UART1_BASEADDR != CONSOLE_BASE || STDOUT_BASEADDRESS != CONSOLE_BASE
#error Regenerate the R5 BSP with UART1 selected as standalone_stdout
#endif
volatile char board_log[4096];
volatile uint32_t board_log_written;
volatile uint32_t board_uart_dropped;
static XUartPs uart;
static bool uart_ready;
void board_console_init(void)
{
    XUartPs_Config *cfg=XUartPs_LookupConfig(CONSOLE_BASE);
    if (!cfg || XUartPs_CfgInitialize(&uart,cfg,cfg->BaseAddress)!=XST_SUCCESS)
        board_assert(__FILE__,__LINE__);
    XUartPsFormat format={115200,XUARTPS_FORMAT_8_BITS,
                         XUARTPS_FORMAT_NO_PARITY,XUARTPS_FORMAT_1_STOP_BIT};
    if (XUartPs_SetDataFormat(&uart,&format)!=XST_SUCCESS)
        board_assert(__FILE__,__LINE__);
    XUartPs_SetOperMode(&uart,XUARTPS_OPER_MODE_NORMAL);
    XUartPs_SetInterruptMask(&uart,0);
    /* No RTS/CTS flow control on the console connection. */
    XUartPs_WriteReg(CONSOLE_BASE,XUARTPS_MODEMCR_OFFSET,0);
    uart_ready=true;
}
void __wrap_outbyte(char c)
{
    uint32_t cpsr;
    __asm volatile("mrs %0, cpsr\ncpsid i" : "=r"(cpsr) :: "memory");
    board_log[board_log_written & 4095u]=c;
    board_log_written++;
    if (!(cpsr&0x80u)) __asm volatile("cpsie i" ::: "memory");
    if (!uart_ready) return;
    /* Bounded polling also works before the scheduler or with IRQs disabled.
     * Do not allow a stuck UART to prevent fault logging/boot indefinitely. */
    for (unsigned tries=0;tries<100000u;tries++) {
        if (!(XUartPs_ReadReg(CONSOLE_BASE,XUARTPS_SR_OFFSET)&XUARTPS_SR_TXFULL)) {
            /* A task switch between testing space and writing could fill FIFO. */
            __asm volatile("mrs %0, cpsr\ncpsid i" : "=r"(cpsr) :: "memory");
            bool space=!(XUartPs_ReadReg(CONSOLE_BASE,XUARTPS_SR_OFFSET)&XUARTPS_SR_TXFULL);
            if (space) XUartPs_WriteReg(CONSOLE_BASE,XUARTPS_FIFO_OFFSET,(uint8_t)c);
            if (!(cpsr&0x80u)) __asm volatile("cpsie i" ::: "memory");
            if (space) return;
        }
    }
    board_uart_dropped++;
}
