#include "web.h"
#include "board.h"
#include "FreeRTOS.h"
#include "task.h"
#include "FreeRTOS_IP.h"
#include "FreeRTOS_Sockets.h"
#include "xil_printf.h"
#include <stdio.h>
#include <string.h>
#include "web_page.h"
static char request[2048], response[24576];
static int send_all(Socket_t socket,const char *data,size_t size,TickType_t start)
{
    while (size && (TickType_t)(xTaskGetTickCount()-start)<pdMS_TO_TICKS(5000)) {
        BaseType_t n=FreeRTOS_send(socket,data,size,0);
        if (n<=0) return 0;
        data+=n; size-=(size_t)n;
    }
    return size==0;
}
static void serve(Socket_t socket)
{
    TickType_t start=xTaskGetTickCount(); size_t used=0; int parsed=0;
    struct web_request r;
    while (!parsed && used<sizeof(request)-1 && (TickType_t)(xTaskGetTickCount()-start)<pdMS_TO_TICKS(2000)) {
        BaseType_t n=FreeRTOS_recv(socket,request+used,sizeof(request)-1-used,0);
        if (n<=0) break;
        used+=(size_t)n; parsed=web_parse(request,used,&r);
    }
    const char *body="Bad request\n", *type="text/plain; charset=utf-8", *status="400 Bad Request";
    size_t size=strlen(body);
    bool unauthorized=false;
    if (parsed==1 && !strcmp(r.method,"POST")) {
        struct switch_config cfg;settings_get(&cfg,NULL,NULL);
        if (!auth_verify(&cfg,r.authorization)) {
            unauthorized=true;parsed=0;status="401 Unauthorized";
            body="Administrator credentials required\n";size=strlen(body);
            /* Bound retry rate without blocking higher-priority traffic tasks. */
            vTaskDelay(pdMS_TO_TICKS(1000));
        }
    }
    if (parsed==1) {
        if (!strcmp(r.method,"GET") && (!strcmp(r.path,"/") || !strcmp(r.path,"/statistics") || !strcmp(r.path,"/configuration"))) {
            body=web_page;size=sizeof(web_page)-1;type="text/html; charset=utf-8";status="200 OK";
        } else if ((!strcmp(r.method,"GET") || !strcmp(r.method,"POST")) && !strcmp(r.path,"/api/config")) {
            struct switch_config cfg;bool saved,writable;
            settings_get(&cfg,&saved,&writable);
            bool ok=true;
            if (!strcmp(r.method,"POST")) {
                if (!r.credentials) {
                    memcpy(r.settings.username,cfg.username,sizeof(cfg.username));
                    memcpy(r.settings.password_salt,cfg.password_salt,16);
                    memcpy(r.settings.password_hash,cfg.password_hash,32);
                }
                ok=settings_save(&r.settings);
                settings_get(&cfg,&saved,&writable);
            }
            if (ok) {
                size=config_json(response,sizeof(response),&cfg,saved,writable);
                body=response;type="application/json";status=size?"200 OK":"500 Internal Server Error";
            } else {body="Settings were not saved; microSD storage unavailable or write failed\n";size=strlen(body);status="503 Service Unavailable";}
        } else if ((!strcmp(r.method,"GET") || !strcmp(r.method,"POST")) && !strcmp(r.path,"/api/ports")) {
            bool ok=true;
            if (!strcmp(r.method,"POST")) {
                struct switch_config cfg;settings_get(&cfg,NULL,NULL);cfg.admin=(uint8_t)r.mask;
                if (r.advertise[0]) memcpy(cfg.advertise,r.advertise,2);
                ok=settings_save(&cfg);
            }
            struct port_snapshot p; board_ports_snapshot(&p);
            size=web_ports(response,sizeof(response),&p);
            body=response;type="application/json";status="200 OK";
            if (!ok) {body="Port settings were not saved\n";size=strlen(body);type="text/plain";status="503 Service Unavailable";}
        } else if (!strcmp(r.method,"GET") && !strcmp(r.path,"/api/statistics")) {
            struct statistics_snapshot s; struct sensor_snapshot v; struct stp_status st;
            statistics_get(&s); sensors_get(&v); stp_status_get(&st);
            struct port_snapshot p; board_ports_snapshot(&p);
            size=web_stats(response,sizeof(response),&s,&v,board_timestamp_hz(),board_timestamp(),&p,&st);
            body=response;type="application/json";status=size?"200 OK":"500 Internal Server Error";
        } else {status="404 Not Found";body="Not found\n";size=strlen(body);}
    }
    /* Credentials are per request, not retained as an authenticated session. */
    memset(request,0,sizeof(request));memset(r.authorization,0,sizeof(r.authorization));
    /* Flash saves have their own bounded waits; give response transmission
     * a fresh deadline after completing the operation. */
    start=xTaskGetTickCount();
    char header[512];
    int n=snprintf(header,sizeof(header),"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %u\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n%s\r\n",status,type,(unsigned)size,unauthorized?"WWW-Authenticate: Basic realm=\"KR260 configuration\"\r\n":"");
    if (n>0 && (size_t)n<sizeof(header) && send_all(socket,header,(size_t)n,start))
        (void)send_all(socket,body,size,start);
    FreeRTOS_shutdown(socket,FREERTOS_SHUT_RDWR);
    /* Allow queued data and FIN to drain before destroying the socket. */
    char discard[64]; TickType_t closing=xTaskGetTickCount();
    while ((TickType_t)(xTaskGetTickCount()-closing)<pdMS_TO_TICKS(2000))
        if (FreeRTOS_recv(socket,discard,sizeof(discard),0)<0) break;
}
void web_task(void *unused)
{
    (void)unused;
    Socket_t listener=FreeRTOS_socket(FREERTOS_AF_INET,FREERTOS_SOCK_STREAM,FREERTOS_IPPROTO_TCP);
    configASSERT(listener!=FREERTOS_INVALID_SOCKET);
    struct freertos_sockaddr address={0}; address.sin_family=FREERTOS_AF_INET;address.sin_port=FreeRTOS_htons(80);
    configASSERT(FreeRTOS_bind(listener,&address,sizeof(address))==0);
    configASSERT(FreeRTOS_listen(listener,2)==0);
    xil_printf("HTTP management TCP 80; public viewing, authenticated configuration\r\n");
    for (;;) {
        Socket_t client=FreeRTOS_accept(listener,NULL,NULL);
        if (client!=FREERTOS_INVALID_SOCKET && client!=NULL) {
            TickType_t timeout=pdMS_TO_TICKS(250);
            FreeRTOS_setsockopt(client,0,FREERTOS_SO_RCVTIMEO,&timeout,sizeof(timeout));
            FreeRTOS_setsockopt(client,0,FREERTOS_SO_SNDTIMEO,&timeout,sizeof(timeout));
            serve(client); FreeRTOS_closesocket(client);
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}
