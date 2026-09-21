#include "board.h"
#include "FreeRTOS.h"
#include "task.h"
#include "xscugic.h"
#include "xttcps.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"

static XScuGic gic;
static XTtcPs tick, stamp;
static uint32_t stamp_last, stamp_hz;
static uint64_t stamp_high;
#define TICK_BASE 0xff110000UL
#define STAMP_BASE 0xff120000UL
#define TICK_IRQ 68u

void board_assert(const char *file, unsigned line)
{
    __asm volatile("cpsid if" ::: "memory");
    xil_printf("FATAL %s:%u\r\n", file, line);
    for (;;) __asm volatile("wfi");
}
static void timer_init(XTtcPs *timer, uintptr_t base)
{
    XTtcPs_Config *cfg = XTtcPs_LookupConfig(base);
    configASSERT(cfg != NULL);
    configASSERT(XTtcPs_CfgInitialize(timer, cfg, cfg->BaseAddress) == XST_SUCCESS);
    XTtcPs_Stop(timer);
    XTtcPs_DisableInterrupts(timer, XTTCPS_IXR_ALL_MASK);
}
void board_init(void)
{
    /* Initial bring-up deliberately disables the R5 D-cache: CPU DMA uses DDR
     * descriptors and bounce buffers, with explicit ownership barriers. */
    Xil_DCacheDisable();
    board_console_init();
    XScuGic_Config *cfg = XScuGic_LookupConfig(0xf9000000UL);
    configASSERT(cfg != NULL);
    configASSERT(cfg->DistBaseAddress == configINTERRUPT_CONTROLLER_BASE_ADDRESS);
    configASSERT(cfg->CpuBaseAddress == configINTERRUPT_CONTROLLER_BASE_ADDRESS +
                 configINTERRUPT_CONTROLLER_CPU_INTERFACE_OFFSET);
    configASSERT(XScuGic_CfgInitialize(&gic, cfg, cfg->CpuBaseAddress) == XST_SUCCESS);
    timer_init(&stamp, STAMP_BASE);
    XTtcPs_SetOptions(&stamp, XTTCPS_OPTION_WAVE_DISABLE);
    XTtcPs_SetPrescaler(&stamp, 6); /* divide by 2^(6+1); continuous 32-bit counter */
    stamp_hz = stamp.Config.InputClockHz / 128u;
    configASSERT(stamp_hz != 0);
    XTtcPs_ResetCounterValue(&stamp);
    XTtcPs_Start(&stamp);
    mmio_write(DIAG_BASE + 0x1c, 0); /* link task polls, IRQ unused for now */
    mmio_write(DIAG_BASE + LINK_CLR, PHYSICAL_PORT_MASK);
    mmio_write(DIAG_BASE + LINK_SET, CPU_PORT_MASK);
    xil_printf("R5-0: fabric CPU port, TTC0 tick / TTC1 timestamp\r\n");
}
static uint64_t stamp_sample(void)
{
    uint32_t now = XTtcPs_GetCounterValue(&stamp);
    if (now < stamp_last) stamp_high += UINT64_C(1) << 32;
    stamp_last = now;
    return stamp_high | now;
}
uint64_t board_timestamp(void)
{
    uint32_t cpsr;
    __asm volatile("mrs %0, cpsr\ncpsid i" : "=r"(cpsr) :: "memory");
    uint64_t value = stamp_sample();
    if (!(cpsr & 0x80u)) __asm volatile("cpsie i" ::: "memory");
    return value;
}
uint32_t board_timestamp_hz(void) { return stamp_hz; }
void board_tick_clear(void)
{
    (void)XTtcPs_GetInterruptStatus(&tick); /* read-to-clear */
    (void)stamp_sample(); /* extend free-running counter once each millisecond */
}
void board_tick_setup(void)
{
    XInterval interval; u8 prescale;
    timer_init(&tick, TICK_BASE);
    XTtcPs_SetOptions(&tick, XTTCPS_OPTION_INTERVAL_MODE | XTTCPS_OPTION_WAVE_DISABLE);
    XTtcPs_CalcIntervalFromFreq(&tick, configTICK_RATE_HZ, &interval, &prescale);
    configASSERT(interval != 0 && interval != (XInterval)-1);
    XTtcPs_SetInterval(&tick, interval);
    XTtcPs_SetPrescaler(&tick, prescale);
    XScuGic_SetPriorityTriggerType(&gic, TICK_IRQ, 0xf0, 1);
    XScuGic_Enable(&gic, TICK_IRQ);
    (void)XTtcPs_GetInterruptStatus(&tick);
    XTtcPs_EnableInterrupts(&tick, XTTCPS_IXR_INTERVAL_MASK);
    XTtcPs_Start(&tick);
}
/* The upstream assembly already reads IAR and writes EOI. Do not dispatch via
 * XScuGic_InterruptHandler, which would acknowledge the interrupt twice. */
void vApplicationIRQHandler(uint32_t iar)
{
    if ((iar & 0x3ffu) == TICK_IRQ) FreeRTOS_Tick_Handler();
}
void vApplicationMallocFailedHook(void) { board_assert(__FILE__, __LINE__); }
void vApplicationStackOverflowHook(TaskHandle_t t, char *name)
{ (void)t; (void)name; board_assert(__FILE__, __LINE__); }
