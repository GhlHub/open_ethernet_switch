#include "web.h"
#include "board.h"
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"
#include "FreeRTOS_IP.h"
#include "FreeRTOS_Sockets.h"
#include "xil_printf.h"
#include <stdio.h>
#include <string.h>
#include "web_page.h"
enum { HTTP_WORKERS=4, HTTP_QUEUE_DEPTH=8, HTTP_BACKLOG=12 };
struct http_buffers { char request[2048], response[24576]; };
struct http_job { Socket_t socket; TickType_t accepted; };
static struct http_buffers buffers[HTTP_WORKERS];
static QueueHandle_t clients;
/* Serializes authentication + configuration read/modify/save, including the
 * single-owner USB/FAT stack. Statistics and ordinary pages do not take it. */
static SemaphoreHandle_t settings_lock;
static int send_all(Socket_t socket,const char *data,size_t size,TickType_t start)
{
    while (size && (TickType_t)(xTaskGetTickCount()-start)<pdMS_TO_TICKS(5000)) {
        BaseType_t n=FreeRTOS_send(socket,data,size,0);
        if (n<=0) return 0;
        data+=n; size-=(size_t)n;
    }
    return size==0;
}
static void serve(Socket_t socket,struct http_buffers *buffer)
{
    char *request=buffer->request, *response=buffer->response;
    TickType_t start=xTaskGetTickCount(); size_t used=0; int parsed=0;
    struct web_request r;
    while (!parsed && used<sizeof(buffer->request)-1 && (TickType_t)(xTaskGetTickCount()-start)<pdMS_TO_TICKS(2000)) {
        BaseType_t n=FreeRTOS_recv(socket,request+used,sizeof(buffer->request)-1-used,0);
        if (n<=0) break;
        used+=(size_t)n; parsed=web_parse(request,used,&r);
    }
    const char *body="Bad request\n", *type="text/plain; charset=utf-8", *status="400 Bad Request";
    size_t size=strlen(body);
    bool unauthorized=false, locked=false;
    if (parsed==1 && (!strcmp(r.method,"POST") ||
        (!strcmp(r.method,"GET") && !strcmp(r.path,"/api/config")))) {
        locked=xSemaphoreTake(settings_lock,pdMS_TO_TICKS(2000))==pdTRUE;
        if (!locked) {
            parsed=0;status="503 Service Unavailable";
            body="Configuration busy; retry later\n";size=strlen(body);
        }
    }
    if (parsed==1 && !strcmp(r.method,"POST")) {
        struct switch_config cfg;settings_get(&cfg,NULL,NULL);
        if (!auth_verify(&cfg,r.authorization)) {
            unauthorized=true;parsed=0;status="401 Unauthorized";
            body="Administrator credentials required\n";size=strlen(body);
            xSemaphoreGive(settings_lock);locked=false;
            /* Penalize only this worker; other clients can still be served. */
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
                size=config_json(response,sizeof(buffer->response),&cfg,saved,writable);
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
            size=web_ports(response,sizeof(buffer->response),&p);
            body=response;type="application/json";status="200 OK";
            if (!ok) {body="Port settings were not saved\n";size=strlen(body);type="text/plain";status="503 Service Unavailable";}
        } else if (!strcmp(r.method,"GET") && !strcmp(r.path,"/api/statistics")) {
            struct statistics_snapshot s; struct sensor_snapshot v; struct stp_status st;
            statistics_get(&s); sensors_get(&v); stp_status_get(&st);
            struct port_snapshot p; board_ports_snapshot(&p);
            size=web_stats(response,sizeof(buffer->response),&s,&v,board_timestamp_hz(),board_timestamp(),&p,&st);
            body=response;type="application/json";status=size?"200 OK":"500 Internal Server Error";
        } else {status="404 Not Found";body="Not found\n";size=strlen(body);}
    }
    if (locked) xSemaphoreGive(settings_lock);
    /* Credentials are per request, not retained as an authenticated session. */
    memset(request,0,sizeof(buffer->request));memset(r.authorization,0,sizeof(r.authorization));
    /* SD saves have their own bounded waits; give response transmission
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
static void worker(void *arg)
{
    struct http_buffers *buffer=arg;
    struct http_job job;
    for (;;) {
        if (xQueueReceive(clients,&job,portMAX_DELAY)!=pdTRUE) continue;
        /* Bound time spent queued behind slow clients. */
        if ((TickType_t)(xTaskGetTickCount()-job.accepted)<pdMS_TO_TICKS(2000))
            serve(job.socket,buffer);
        FreeRTOS_closesocket(job.socket);
    }
}
void web_task(void *unused)
{
    (void)unused;
    clients=xQueueCreate(HTTP_QUEUE_DEPTH,sizeof(struct http_job));
    settings_lock=xSemaphoreCreateMutex();
    configASSERT(clients && settings_lock);
    for (unsigned i=0;i<HTTP_WORKERS;i++)
        configASSERT(xTaskCreate(worker,"http-worker",4096,&buffers[i],1,NULL)==pdPASS);
    Socket_t listener=FreeRTOS_socket(FREERTOS_AF_INET,FREERTOS_SOCK_STREAM,FREERTOS_IPPROTO_TCP);
    configASSERT(listener!=FREERTOS_INVALID_SOCKET);
    struct freertos_sockaddr address={0}; address.sin_family=FREERTOS_AF_INET;address.sin_port=FreeRTOS_htons(80);
    configASSERT(FreeRTOS_bind(listener,&address,sizeof(address))==0);
    /* FreeRTOS+TCP counts all child sockets, including accepted clients. */
    configASSERT(FreeRTOS_listen(listener,HTTP_BACKLOG)==0);
    xil_printf("HTTP management TCP 80; %u workers, %u connections; authenticated configuration\r\n",
               HTTP_WORKERS,HTTP_BACKLOG);
    for (;;) {
        Socket_t client=FreeRTOS_accept(listener,NULL,NULL);
        if (client!=FREERTOS_INVALID_SOCKET && client!=NULL) {
            TickType_t timeout=pdMS_TO_TICKS(250);
            FreeRTOS_setsockopt(client,0,FREERTOS_SO_RCVTIMEO,&timeout,sizeof(timeout));
            FreeRTOS_setsockopt(client,0,FREERTOS_SO_SNDTIMEO,&timeout,sizeof(timeout));
            struct http_job job={client,xTaskGetTickCount()};
            /* An overloaded pool must not block acceptance indefinitely. */
            if (xQueueSend(clients,&job,0)!=pdTRUE) FreeRTOS_closesocket(client);
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}
