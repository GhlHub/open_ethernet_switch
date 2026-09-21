#include "board.h"
#include "FreeRTOS.h"
#include "task.h"
static void startup(void *arg)
{
    (void)arg;
    network_start();
    configASSERT(xTaskCreate(board_link_task,"links",2048,NULL,2,NULL)==pdPASS);
    vTaskDelete(NULL);
}
int main(void)
{
    /* FSBL must initialize PS clocks/DDR/PHY resets and load the fabric first. */
    board_init();
    configASSERT(xTaskCreate(startup,"startup",2048,NULL,5,NULL)==pdPASS);
    vTaskStartScheduler();
    board_assert(__FILE__,__LINE__);
    return 1;
}
