#include "mac_table_web.h"
#include "mac_dump.h"
#include "ip_discovery.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static unsigned starts;
static unsigned discovery_mode;
size_t ip_discovery_lookup(const uint8_t mac[6],struct ip_observation ips[IP_DISCOVERY_PER_MAC])
{
    assert(mac[0]==0 && mac[1]==10 && mac[5]==0x45);
    if(discovery_mode!=1)return 0;
    for(unsigned i=0;i<4;i++)ips[i]=(struct ip_observation){{223,255,255,254-i},599999};
    return 4;
}
int network_cached_ipv4(const uint8_t mac[6],uint8_t ip[4])
{
    (void)mac;
    if(discovery_mode!=2)return 0;
    memcpy(ip,"\x0a\x00\x01\x8c",4);return 1;
}
static enum mac_dump_result result=MAC_DUMP_BUSY;
static struct mac_dump_record *dma;
static uint64_t now;
uint64_t board_timestamp(void){return now++;}
uint32_t board_timestamp_hz(void){return 1000;}
enum mac_dump_result mac_dump_start(struct mac_dump_record *p,size_t bytes)
{
    assert(bytes==32768 && !((uintptr_t)p&255));
    starts++;dma=p;result=MAC_DUMP_BUSY;return MAC_DUMP_STARTED;
}
enum mac_dump_result mac_dump_poll(uint32_t *bytes,uint32_t *error)
{
    if(result==MAC_DUMP_DONE)*bytes=32768,*error=0;
    if(result==MAC_DUMP_ERROR)*bytes=256,*error=1;
    return result;
}
static char out[24576];
static void query(const char *path,bool refresh,int code)
{
    size_t len=99;
    assert(web_mac_table(out,sizeof(out),path,refresh,&len)==code);
    if(code<400)assert(strlen(out)==len);
}
int main(void)
{
    query("/api/mac-table",false,200);assert(starts==0 && strstr(out,"\"ready\":false"));
    query("/api/mac-table/0",false,200);assert(starts==0);
    query("/api/mac-table",true,202);assert(starts==1);
    for(unsigned i=0;i<10;i++)query("/api/mac-table",false,200);
    query("/api/mac-table",true,202);assert(starts==1); /* coalesce active requests */
    for(unsigned i=0;i<2048;i++)dma[i]=(struct mac_dump_record){.mac_low=0x350f3745,.mac_high=0x000a,.port_mask=6,.age_seconds=300,.index=i,.flags=1};
    result=MAC_DUMP_DONE;
    query("/api/mac-table",false,200);
    assert(strstr(out,"\"count\":2048") && strstr(out,"\"generation\":1") && starts==1);
    for(unsigned i=0;i<16;i++) {
        char path[40],last[32];snprintf(path,sizeof(path),"/api/mac-table/%u",i);
        query(path,false,200);
        snprintf(last,sizeof(last),"[%u,\"",i*128+127);assert(strstr(out,last));
        assert(strstr(out,"00:0a:35:0f:37:45") && strstr(out,",6,300,[]]"));
    }
    discovery_mode=1;query("/api/mac-table/0",false,200);
    assert(strstr(out,"[\"223.255.255.254\",599999]") && strstr(out,"[\"223.255.255.251\",599999]"));
    discovery_mode=2;query("/api/mac-table/0",false,200);
    assert(strstr(out,"[\"10.0.1.140\",null]"));
    discovery_mode=0;
    query("/api/mac-table/16",false,404);
    query("/api/mac-table/0?x",false,404);
    query("/",false,404);
    query("/api/mac-table/0",true,404);assert(starts==1);
    query("/api/mac-table",true,202);assert(starts==2);
    memset(dma,0,32768);
    query("/api/mac-table/0",false,200);
    assert(strstr(out,",6,300,[]]") && strstr(out,"\"generation\":1")); /* old snapshot isolated */
    result=MAC_DUMP_ERROR;
    query("/api/mac-table",false,200);
    assert(strstr(out,"\"error\":1") && strstr(out,"\"generation\":1"));
    query("/api/mac-table",true,202);assert(starts==3);
    result=MAC_DUMP_DONE;
    query("/api/mac-table",false,200);
    assert(strstr(out,"\"count\":0") && strstr(out,"\"generation\":2"));
    size_t len;assert(web_mac_table(out,1,"/api/mac-table",false,&len)==500 && len==0);
    assert(starts==3);
    puts("PASS: manual MAC refresh, DMA ownership, cached reads, pagination, full table, errors and concurrent-request coalescing");
}
