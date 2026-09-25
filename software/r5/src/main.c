#include "board.h"
#include "config.h"
#include "statistics.h"
#include "snmp.h"
#include "web.h"
#include "stp.h"
#include "FreeRTOS.h"
#include "task.h"
static void startup(void *arg)
{
    (void)arg;
    settings_init();
    configASSERT(xTaskCreate(statistics_task,"stats",1024,NULL,3,NULL)==pdPASS);
    configASSERT(xTaskCreate(sensors_task,"sensors",1024,NULL,1,NULL)==pdPASS);
    network_start();
    configASSERT(xTaskCreate(snmp_task,"snmp",4096,NULL,1,NULL)==pdPASS);
    configASSERT(xTaskCreate(web_task,"http",4096,NULL,1,NULL)==pdPASS);
    configASSERT(xTaskCreate(board_link_task,"links",2048,NULL,2,NULL)==pdPASS);
    configASSERT(xTaskCreate(stp_task,"stp",2048,NULL,2,NULL)==pdPASS);
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
