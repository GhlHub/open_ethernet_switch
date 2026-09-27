#include "ip_discovery.h"
#include "board.h"
#include "FreeRTOS.h"
#include "task.h"
#include <string.h>
struct entry { uint8_t mac[6], ip[4]; uint64_t seen; unsigned valid; };
static struct entry entries[IP_DISCOVERY_CAPACITY];
static uint64_t milliseconds(void)
{
    uint32_t hz=board_timestamp_hz();
    return hz ? board_timestamp()*1000/hz : 0;
}
void ip_discovery_observe(const uint8_t *f,size_t n)
{
    /* Validate Ethernet, ARP hardware/protocol sizes, opcode and sender.
     * Ignore tagged traffic: the current MAC table has no VLAN key. */
    if(n<42 || f[12]!=8 || f[13]!=6 || f[14]!=0 || f[15]!=1 ||
       f[16]!=8 || f[17]!=0 || f[18]!=6 || f[19]!=4 || f[20]!=0 ||
       (f[21]!=1 && f[21]!=2) || (f[22]&1) ||
       !memcmp(f+22,"\0\0\0\0\0\0",6) || memcmp(f+6,f+22,6) ||
       f[28]==0 || f[28]==127 || f[28]>=224) return;
    uint64_t now=milliseconds();
    taskENTER_CRITICAL();
    unsigned slot=0, same=0, oldest_same=0;
    for(unsigned i=0;i<IP_DISCOVERY_CAPACITY;i++) {
        if(entries[i].valid && now-entries[i].seen>=IP_DISCOVERY_TTL_MS) entries[i].valid=0;
        if(!entries[i].valid || (entries[slot].valid && entries[i].seen<entries[slot].seen)) slot=i;
        if(entries[i].valid && !memcmp(entries[i].mac,f+22,6)) {
            if(!same || entries[i].seen<entries[oldest_same].seen) oldest_same=i;
            same++;
        }
    }
    if(same>=IP_DISCOVERY_PER_MAC) slot=oldest_same;
    for(unsigned i=0;i<IP_DISCOVERY_CAPACITY;i++)
        if(entries[i].valid && !memcmp(entries[i].ip,f+28,4)) {
            if(same>=IP_DISCOVERY_PER_MAC && memcmp(entries[i].mac,f+22,6))
                entries[oldest_same].valid=0;
            slot=i;break;
        }
    memcpy(entries[slot].mac,f+22,6); memcpy(entries[slot].ip,f+28,4);
    entries[slot].seen=now; entries[slot].valid=1;
    taskEXIT_CRITICAL();
}
size_t ip_discovery_lookup(const uint8_t mac[6],struct ip_observation out[IP_DISCOVERY_PER_MAC])
{
    size_t count=0; uint64_t now=milliseconds();
    taskENTER_CRITICAL();
    for(unsigned i=0;i<IP_DISCOVERY_CAPACITY && count<IP_DISCOVERY_PER_MAC;i++) {
        uint64_t age=now-entries[i].seen;
        if(entries[i].valid && age<IP_DISCOVERY_TTL_MS && !memcmp(entries[i].mac,mac,6)) {
            memcpy(out[count].ip,entries[i].ip,4);out[count++].age_ms=(uint32_t)age;
        }
    }
    taskEXIT_CRITICAL();
    return count;
}
