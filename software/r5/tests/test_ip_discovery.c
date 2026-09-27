#include "ip_discovery.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static uint64_t now;
uint64_t board_timestamp(void){return now;}
uint32_t board_timestamp_hz(void){return 1000;}
static uint8_t frame[60]={0xff,0xff,0xff,0xff,0xff,0xff, 2,0,0,0,0,1,
    8,6,0,1,8,0,6,4,0,1, 2,0,0,0,0,1, 10,0,1,140};
static struct ip_observation ips[4];
static size_t lookup(void){return ip_discovery_lookup(frame+6,ips);}
int main(void)
{
    for(unsigned n=0;n<42;n++)ip_discovery_observe(frame,n);
    assert(!lookup());
    const unsigned offsets[]={12,13,14,15,16,17,18,19,20,21,22,28};
    for(unsigned i=0;i<sizeof(offsets)/sizeof(*offsets);i++) {
        unsigned at=offsets[i];uint8_t save=frame[at];frame[at]=255;
        ip_discovery_observe(frame,sizeof frame);assert(!lookup());frame[at]=save;
    }
    ip_discovery_observe(frame,sizeof frame);now=1250;
    assert(lookup()==1 && ips[0].age_ms==1250 && ips[0].ip[3]==140);
    frame[21]=2;ip_discovery_observe(frame,sizeof frame);
    assert(lookup()==1 && ips[0].age_ms==0);
    for(unsigned i=141;i<=145;i++) {now++;frame[31]=i;ip_discovery_observe(frame,sizeof frame);}
    assert(lookup()==4);
    for(unsigned i=0;i<4;i++)assert(ips[i].ip[3]>=142);
    /* IP reassignment replaces the old MAC association. */
    uint8_t old[6];memcpy(old,frame+6,6);frame[11]=frame[27]=2;
    ip_discovery_observe(frame,sizeof frame);
    assert(lookup()==1 && ip_discovery_lookup(old,ips)==3);
    /* Moving an existing address to a MAC already holding four stays bounded. */
    for(unsigned i=146;i<149;i++){now++;frame[31]=i;ip_discovery_observe(frame,sizeof frame);}
    frame[31]=142;ip_discovery_observe(frame,sizeof frame);assert(lookup()==4);
    now+=IP_DISCOVERY_TTL_MS;assert(!lookup());
    /* Global capacity evicts oldest observations rather than growing storage. */
    for(unsigned i=1;i<=129;i++) {
        now++;frame[11]=frame[27]=i;frame[31]=i;
        ip_discovery_observe(frame,sizeof frame);
    }
    assert(lookup()==1);frame[11]=1;assert(!lookup());
    puts("PASS: malformed/truncated ARP, requests/replies, age, duplicates, multiple IPs, reassignment, expiry and bounded eviction");
}
