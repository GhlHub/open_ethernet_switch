#include "mac_table_web.h"
#include "mac_dump.h"
#include "board.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
/* Separate staging and published snapshots: readers never touch DMA-owned DDR. */
static struct mac_dump_record staging[MAC_DUMP_ENTRIES] __attribute__((aligned(256)));
static struct mac_dump_record published[MAC_DUMP_ENTRIES];
static bool busy, ready;
static uint32_t generation, error, completed, count;
static uint64_t captured;
static void append(char *out,size_t capacity,size_t *used,const char *fmt,...)
{
    if(*used>=capacity)return;
    va_list ap;va_start(ap,fmt);
    int n=vsnprintf(out+*used,capacity-*used,fmt,ap);va_end(ap);
    if(n<0 || (size_t)n>=capacity-*used)*used=capacity;
    else *used+=(size_t)n;
}
int web_mac_table(char *out,size_t capacity,const char *path,bool refresh,size_t *length)
{
    unsigned page=16;
    if(strcmp(path,"/api/mac-table")) {
        if(strncmp(path,"/api/mac-table/",15) || refresh)return *length=0,404;
        const char *p=path+15;
        if(*p<'0' || *p>'9')
            return *length=0,404;
        char *end;unsigned long n=strtoul(p,&end,10);
        if(*end || n>=16)return *length=0,404;
        page=(unsigned)n;
    }
    if(busy) {
        enum mac_dump_result r=mac_dump_poll(&completed,&error);
        if(r==MAC_DUMP_DONE || r==MAC_DUMP_ERROR) {
            busy=false;
            if(r==MAC_DUMP_DONE && completed==MAC_DUMP_BYTES) {
                memcpy(published,staging,sizeof(published));
                count=0;
                for(unsigned i=0;i<MAC_DUMP_ENTRIES;i++)if(published[i].flags&1)count++;
                ready=true;if(++generation==0)generation++;
                captured=board_timestamp();
            } else if(!error)error=100;
        }
    }
    if(refresh && !busy) {
        enum mac_dump_result r=mac_dump_start(staging,sizeof(staging));
        if(r==MAC_DUMP_STARTED) {busy=true;error=completed=0;}
        else error=100+(unsigned)r;
    }
    uint32_t hz=board_timestamp_hz();
    uint64_t age=ready && hz?(board_timestamp()-captured)*1000/hz:0;
    size_t used=0;
    append(out,capacity,&used,"{\"busy\":%s,\"ready\":%s,\"generation\":%lu,\"age_ms\":%llu,\"count\":%lu,\"error\":%lu,\"completed_bytes\":%lu,\"pages\":16,\"entries\":[",
        busy?"true":"false",ready?"true":"false",(unsigned long)generation,
        (unsigned long long)age,(unsigned long)count,(unsigned long)error,(unsigned long)completed);
    bool comma=false;
    if(ready && page<16)for(unsigned i=page*128;i<(page+1)*128;i++) {
        const struct mac_dump_record *r=&published[i];
        if(!(r->flags&1))continue;
        append(out,capacity,&used,"%s[%u,\"%02x:%02x:%02x:%02x:%02x:%02x\",%u,%u]",
            comma?",":"",r->index,r->mac_high>>8,r->mac_high&255,
            (unsigned)(r->mac_low>>24),(unsigned)((r->mac_low>>16)&255),
            (unsigned)((r->mac_low>>8)&255),(unsigned)(r->mac_low&255),
            r->port_mask,r->age_seconds);
        comma=true;
    }
    append(out,capacity,&used,"]}");
    if(used>=capacity)return *length=0,500;
    *length=used;return refresh && busy?202:200;
}
