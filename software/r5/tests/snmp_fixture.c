#include "snmp.h"
#include <assert.h>
size_t fixture_respond(const uint8_t *in,size_t n,uint8_t *out,size_t cap)
{
    static struct snmp_mib mib;
    struct statistics_snapshot s={0};
    struct sensor_snapshot v={0};
    s.available=true; s.capabilities=0x53540101u|(STATS_DDR<<1)|(STATS_DEBUG<<2);
    s.timestamp=900; s.polls=42; s.port[0][0]=UINT64_MAX;
    s.port[1][0]=UINT64_C(1)<<63;
    s.port[2][0]=UINT64_C(1)<<32;
#if STATS_DDR
    s.ddr[0][3]=123;
#endif
    v.timestamp=950; v.valid_mask=7; v.temperature_mc[0]=-12345;
    v.som_current_ua=-1250;
    snmp_mib_build(&mib,&s,&v,1000,1000,9876,0x31);
    assert(mib.count==87+36*STATS_DDR+32*STATS_DEBUG);
    return snmp_respond(in,n,out,cap,"public",&mib);
}
#ifdef FUZZ_MAIN
#include <stdlib.h>
int main(void)
{
    uint8_t in[SNMP_PACKET_MAX+1],out[SNMP_PACKET_MAX];
    for (unsigned i=0;i<100000;i++) {
        size_t n=rand()%sizeof(in);
        for (size_t j=0;j<n;j++) in[j]=(uint8_t)rand();
        fixture_respond(in,n,out,sizeof(out));
    }
    return 0;
}
#endif
