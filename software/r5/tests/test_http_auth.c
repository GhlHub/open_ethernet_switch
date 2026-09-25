#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "../src/web_task.c"
static struct switch_config current;
static unsigned saves;
static bool save_fails;
static char incoming[2048],outgoing[65536];
static size_t read_offset,written;
static TickType_t ticks;
TickType_t xTaskGetTickCount(void){return ticks++;}
void vTaskDelay(TickType_t n){ticks+=n;}
int xil_printf(const char *fmt,...){(void)fmt;return 0;}
void settings_get(struct switch_config *c,bool *s,bool *w){*c=current;if(s)*s=true;if(w)*w=true;}
bool settings_save(const struct switch_config *c){saves++;if(save_fails)return false;current=*c;return true;}
void board_ports_snapshot(struct port_snapshot *p){memset(p,0,sizeof(*p));p->admin=current.admin;}
void statistics_get(struct statistics_snapshot *s){memset(s,0,sizeof(*s));}
void sensors_get(struct sensor_snapshot *s){memset(s,0,sizeof(*s));}
void stp_status_get(struct stp_status *s){memset(s,0,sizeof(*s));}
uint32_t board_timestamp_hz(void){return 1000;}
uint64_t board_timestamp(void){return ticks;}
Socket_t FreeRTOS_socket(int a,int b,int c){(void)a;(void)b;(void)c;return NULL;}
int FreeRTOS_bind(Socket_t a,const struct freertos_sockaddr *b,size_t c){(void)a;(void)b;(void)c;return 0;}
int FreeRTOS_listen(Socket_t a,int b){(void)a;(void)b;return 0;}
Socket_t FreeRTOS_accept(Socket_t a,void *b,void *c){(void)a;(void)b;(void)c;return NULL;}
int FreeRTOS_setsockopt(Socket_t a,int b,int c,const void *d,size_t e){(void)a;(void)b;(void)c;(void)d;(void)e;return 0;}
int FreeRTOS_closesocket(Socket_t a){(void)a;return 0;}
int FreeRTOS_shutdown(Socket_t a,int b){(void)a;(void)b;return 0;}
int FreeRTOS_recv(Socket_t socket,void *p,size_t size,int flags)
{
    (void)socket;(void)flags;size_t n=strlen(incoming)-read_offset;if(!n)return -1;
    if(n>size)n=size;
    if(n>13)n=13;
    memcpy(p,incoming+read_offset,n);read_offset+=n;return (int)n;
}
int FreeRTOS_send(Socket_t socket,const void *p,size_t n,int flags)
{
    (void)socket;(void)flags;assert(written+n<sizeof(outgoing));memcpy(outgoing+written,p,n);written+=n;outgoing[written]=0;return (int)n;
}
static void query(const char *method,const char *path,const char *auth,const char *body,unsigned status)
{
    snprintf(incoming,sizeof(incoming),"%s %s HTTP/1.1\r\n%sContent-Length: %u\r\nX-KR260-Request: 1\r\n\r\n%s",method,path,auth,(unsigned)strlen(body),body);
    read_offset=written=0;serve((void *)1);
    char expected[32];snprintf(expected,sizeof(expected),"HTTP/1.1 %u ",status);assert(!strncmp(outgoing,expected,strlen(expected)));
    if(status==401)assert(strstr(outgoing,"WWW-Authenticate: Basic"));
}
int main(void)
{
    config_defaults(&current);
    query("GET","/statistics","","",200);query("GET","/configuration","","",200);
    query("GET","/api/statistics","","",200);query("GET","/api/config","","",200);
    assert(!strstr(outgoing,"password_hash")&&!strstr(outgoing,"password_salt"));
    query("POST","/api/ports","","mask=30",401);assert(!saves&&current.admin==31);
    query("POST","/api/ports","Authorization: Basic YWRtaW46YmFk\r\n","mask=30",401);assert(!saves);
    const char *good="Authorization: Basic YWRtaW46YWRtaW4=\r\n";
    query("POST","/api/ports",good,"mask=30",200);assert(saves==1&&current.admin==30);
    const char *form="mask=31&adv0=4&adv1=7&adv2=7&adv3=7&sfp=0&dhcp=1&ip=0.0.0.0&netmask=0.0.0.0&gateway=0.0.0.0";
    query("POST","/api/config","",form,401);assert(saves==1);
    query("POST","/api/config",good,form,200);assert(saves==2&&current.admin==31);
    save_fails=true;query("POST","/api/ports",good,"mask=29",503);assert(current.admin==31);
    query("POST","/api/ports","Authorization: Basic YWRtaW46YWRtaW4=\r\nAuthorization: Basic YWRtaW46YWRtaW4=\r\n","mask=30",400);
    query("POST","/api/ports",good,"mask=32",400);assert(saves==3);
    puts("PASS: real HTTP handler keeps viewing public, rejects missing/wrong/duplicate credentials, gates both write APIs and reports failed saves");
}
