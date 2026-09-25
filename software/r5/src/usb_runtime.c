/* Single-owner libpayload adapter. USB allocations never use Ethernet DMA or
 * the FreeRTOS heap. Headers allow aligned blocks to be freed and coalesced. */
#include "board.h"
#include "FreeRTOS.h"
#include "task.h"
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <sys/time.h>
#include <stdarg.h>
#include <stdio.h>
void usb_udelay(unsigned us)
{
    uint64_t end=board_timestamp()+((uint64_t)us*board_timestamp_hz()+999999)/1000000;
    while (board_timestamp()<end) __asm volatile("nop");
}
void usb_mdelay(unsigned ms)
{
    if (xTaskGetSchedulerState()==taskSCHEDULER_RUNNING) vTaskDelay(pdMS_TO_TICKS(ms)+1);
    else while (ms--) usb_udelay(1000);
}
int usb_gettimeofday(struct timeval *tv,void *tz)
{
    (void)tz;uint64_t us=board_timestamp()*1000000/board_timestamp_hz();
    tv->tv_sec=us/1000000;tv->tv_usec=us%1000000;return 0;
}
void usb_fatal(const char *fmt,...)
{
    va_list ap;va_start(ap,fmt);vprintf(fmt,ap);va_end(ap);
    board_assert(__FILE__,__LINE__);
    for (;;) {}
}
