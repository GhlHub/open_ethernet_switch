#include "snmp.h"
#include "board.h"
#include "FreeRTOS.h"
#include "task.h"
#include "FreeRTOS_IP.h"
#include "FreeRTOS_Sockets.h"
#include "xil_printf.h"
static struct snmp_mib mib;
static uint8_t request[SNMP_PACKET_MAX+1],reply[SNMP_PACKET_MAX];
void snmp_task(void *unused)
{
    (void)unused;
    uint64_t started=board_timestamp();
    Socket_t socket=FreeRTOS_socket(FREERTOS_AF_INET,FREERTOS_SOCK_DGRAM,FREERTOS_IPPROTO_UDP);
    configASSERT(socket!=FREERTOS_INVALID_SOCKET);
    TickType_t timeout=pdMS_TO_TICKS(1000),send_timeout=0;
    UBaseType_t queue_limit=4;
    configASSERT(FreeRTOS_setsockopt(socket,0,FREERTOS_SO_RCVTIMEO,&timeout,sizeof(timeout))==0);
    configASSERT(FreeRTOS_setsockopt(socket,0,FREERTOS_SO_SNDTIMEO,&send_timeout,sizeof(send_timeout))==0);
    configASSERT(FreeRTOS_setsockopt(socket,0,FREERTOS_SO_UDP_MAX_RX_PACKETS,&queue_limit,sizeof(queue_limit))==0);
    struct freertos_sockaddr address={0};
    address.sin_family=FREERTOS_AF_INET;
    address.sin_port=FreeRTOS_htons(161);
    configASSERT(FreeRTOS_bind(socket,&address,sizeof(address))==0);
    xil_printf("SNMPv2c read-only UDP 161; example/configured PEN %u\r\n",(unsigned)SNMP_ENTERPRISE);
    for (;;) {
        struct freertos_sockaddr peer={0}; socklen_t peerlen=sizeof(peer);
        int32_t n=FreeRTOS_recvfrom(socket,request,sizeof(request),0,&peer,&peerlen);
        if (n>0 && n<=SNMP_PACKET_MAX) {
            struct statistics_snapshot s;
            struct sensor_snapshot v;
            statistics_get(&s); sensors_get(&v);
            uint64_t now=board_timestamp(); uint32_t hz=board_timestamp_hz();
            uint64_t elapsed=now-started;
            uint32_t uptime=(uint32_t)((elapsed/hz)*100u+(elapsed%hz)*100u/hz);
            snmp_mib_build(&mib,&s,&v,now,hz,uptime,mmio_read(DIAG_BASE+LINK_STATUS));
            size_t size=snmp_respond(request,(size_t)n,reply,sizeof(reply),SNMP_COMMUNITY,&mib);
            if (size) (void)FreeRTOS_sendto(socket,reply,size,0,&peer,peerlen);
        }
        /* Bound CPU service under a request flood; queue bounded separately. */
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}
