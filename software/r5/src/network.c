#include "board.h"
#include "policy.h"
#include "pstate.h"
#include "FreeRTOS.h"
#include "task.h"
#include "FreeRTOS_IP.h"
#include "FreeRTOS_IP_Private.h"
#include "FreeRTOS_Routing.h"
#include "NetworkBufferManagement.h"
#include "xil_printf.h"
#include <string.h>
static NetworkInterface_t interface;
static NetworkEndPoint_t endpoint;
static volatile bool link_up;
static struct dhcp_policy dhcp;
static TaskHandle_t service;
static uint32_t now_ms(void) { return (uint32_t)(xTaskGetTickCount()*portTICK_PERIOD_MS); }
static BaseType_t initialise(NetworkInterface_t *i)
{ (void)i; return fabric_dma_healthy() && link_up ? pdPASS : pdFAIL; }
static BaseType_t phy_status(NetworkInterface_t *i)
{ (void)i; return fabric_dma_healthy() && link_up ? pdTRUE : pdFALSE; }
static BaseType_t output(NetworkInterface_t *i, NetworkBufferDescriptor_t *const b, BaseType_t release)
{
    (void)i;
    bool ok=link_up && fabric_dma_send(b->pucEthernetBuffer,b->xDataLength);
    if (release) vReleaseNetworkBufferAndDescriptor(b);
    return ok?pdPASS:pdFAIL;
}
void network_link_changed(bool up)
{
    if (link_up==up) return;
    link_up=up;
    if (service) xTaskNotify(service,1u,eSetBits);
}
void network_dhcp_result(int leased)
{
    /* Called in IP task, possibly already in a critical section. */
    taskENTER_CRITICAL(); dhcp_result(&dhcp,leased!=0,now_ms()); taskEXIT_CRITICAL();
    if (!leased && service) xTaskNotify(service,2u,eSetBits);
}
void vApplicationIPNetworkEventHook_Multi(eIPCallbackEvent_t event, NetworkEndPoint_t *e)
{
    if (event==eNetworkUp && e->ipv4_settings.ulIPAddress!=0) {
        xil_printf("DHCP IPv4 acquired: %lu.%lu.%lu.%lu\r\n",
            (unsigned long)(FreeRTOS_ntohl(e->ipv4_settings.ulIPAddress)>>24),
            (unsigned long)((FreeRTOS_ntohl(e->ipv4_settings.ulIPAddress)>>16)&255),
            (unsigned long)((FreeRTOS_ntohl(e->ipv4_settings.ulIPAddress)>>8)&255),
            (unsigned long)(FreeRTOS_ntohl(e->ipv4_settings.ulIPAddress)&255));
    }
}
const char *pcApplicationHostnameHook(void) { return "kr260-switch"; }
/* Bring-up PRNG: timestamp-seeded, not a cryptographic entropy source. */
BaseType_t xApplicationGetRandomNumber(uint32_t *value)
{
    static uint32_t state=0x6b723236u;
    taskENTER_CRITICAL();
    state ^= (uint32_t)board_timestamp();
    state ^= state<<13; state ^= state>>17; state ^= state<<5;
    if (!state) state=0x91e10da5u;
    *value=state;
    taskEXIT_CRITICAL(); return pdTRUE;
}
uint32_t ulApplicationGetNextSequenceNumber(uint32_t a,uint16_t b,uint32_t c,uint16_t d)
{ uint32_t value; (void)a;(void)b;(void)c;(void)d; xApplicationGetRandomNumber(&value); return value; }
static void network_service(void *arg)
{
    (void)arg; static uint8_t frame[1536] __attribute__((aligned(4)));
    bool fault_reported=false;
    for (;;) {
        uint32_t events=0;
        (void)xTaskNotifyWait(0,UINT32_MAX,&events,0);
        if (events&1u) {
            taskENTER_CRITICAL(); dhcp.leased=false; dhcp.retry_wait=false; taskEXIT_CRITICAL();
            FreeRTOS_NetworkDown(&interface);
        }
        if (events&2u) xil_printf("DHCP unsuccessful; retry in 60 seconds\r\n");
        bool retry;
        taskENTER_CRITICAL(); retry=dhcp_retry(&dhcp,link_up,now_ms()); taskEXIT_CRITICAL();
        if (retry) { xil_printf("Retry DHCP\r\n"); FreeRTOS_NetworkDown(&interface); }
        /* Bounded work per iteration so a flooded CPU port cannot starve link service. */
        for (unsigned j=0;j<16;j++) {
            size_t n=fabric_dma_receive(frame,sizeof frame);
            if (!n) break;
            /* IEEE 802.1D reserved block (01:80:C2:00:00:0x): STP/LACP/LLDP/etc,
             * never IP/ARP traffic for this board's own MAC -- see pstate.h. */
            if (n>=6 && frame[0]==0x01 && frame[1]==0x80 && frame[2]==0xc2 &&
                frame[3]==0x00 && frame[4]==0x00 && (frame[5]&0xf0u)==0x00) {
                fabric_ctrl_frame_rx(frame,n); continue;
            }
            if (eConsiderFrameForProcessing(frame)!=eProcessBuffer) continue;
            NetworkBufferDescriptor_t *b=pxGetNetworkBufferWithDescriptor(n,0);
            if (!b) continue;
            memcpy(b->pucEthernetBuffer,frame,n); b->xDataLength=n;
            b->pxInterface=&interface;
            b->pxEndPoint=FreeRTOS_MatchingEndpoint(&interface,b->pucEthernetBuffer);
            IPStackEvent_t event={eNetworkRxEvent,b};
            if (xSendEventStructToIPTask(&event,0)!=pdPASS) vReleaseNetworkBufferAndDescriptor(b);
        }
        if (!fabric_dma_healthy() && !fault_reported) {
            fault_reported=true;
            mmio_write(DIAG_BASE+LINK_CLR,CPU_PORT_MASK|PHYSICAL_PORT_MASK);
            xil_printf("DMA fault: ports disabled, reboot required\r\n");
            network_link_changed(false);
        }
        vTaskDelay(1);
    }
}
void network_start(void)
{
    /* Locally administered development MAC; assign a unique value per board. */
    static const uint8_t mac[6]={0x02,0x4b,0x52,0x32,0x36,0x01};
    static const uint8_t zero[4]={0,0,0,0};
    memset(&interface,0,sizeof interface);
    interface.pcName="fabric0";
    interface.pfInitialise=initialise; interface.pfOutput=output; interface.pfGetPhyLinkStatus=phy_status;
    FreeRTOS_AddNetworkInterface(&interface);
    FreeRTOS_FillEndPoint(&interface,&endpoint,zero,zero,zero,zero,mac);
    endpoint.bits.bWantDHCP=pdTRUE;
    configASSERT(fabric_dma_init());
    configASSERT(FreeRTOS_IPInit_Multi()==pdPASS);
    configASSERT(xTaskCreate(network_service,"fabric-rx",2048,NULL,3,&service)==pdPASS);
}
