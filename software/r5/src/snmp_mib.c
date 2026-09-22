#include "snmp.h"
#include <string.h>
#include <assert.h>
#define INTEGER 0x02
#define STRING 0x04
#define COUNTER 0x41
#define GAUGE 0x42
#define TICKS 0x43
#define COUNTER64 0x46
static const uint32_t root[]={1,3,6,1,4,1,SNMP_ENTERPRISE,1};
static void add(struct snmp_mib *m, unsigned group, unsigned column,
                unsigned row, uint8_t type, uint64_t value, const char *text)
{
    assert(m->count<SNMP_OBJECT_MAX);
    struct snmp_object *o=&m->object[m->count++];
    memset(o,0,sizeof(*o));
    memcpy(o->oid.arc,root,sizeof(root));
    o->oid.length=sizeof(root)/sizeof(root[0]);
    o->oid.arc[o->oid.length++]=group;
    if ((group>=2 && group<=4) || group==6) o->oid.arc[o->oid.length++]=1;
    o->oid.arc[o->oid.length++]=column;
    o->oid.arc[o->oid.length++]=row;
    o->instance_arcs=1; o->type=type; o->number=value; o->text=text;
}
static void system_object(struct snmp_mib *m,unsigned column,uint8_t type,
                           uint64_t value,const char *text)
{
    struct snmp_object *o=&m->object[m->count++];
    *o=(struct snmp_object){.oid={{1,3,6,1,2,1,1,column,0},9},
                           .type=type,.instance_arcs=1,.number=value,.text=text};
}
static uint32_t age(uint64_t now,uint64_t then,uint32_t hz)
{
    if (!then || !hz || now<then) return UINT32_MAX;
    uint64_t elapsed=now-then;
    /* Saturate before multiplying, including a timestamp wrap/corrupt value. */
    if (elapsed/hz > UINT32_MAX/1000u) return UINT32_MAX;
    uint64_t ms=elapsed*1000u/hz;
    return ms>UINT32_MAX?UINT32_MAX:(uint32_t)ms;
}
void snmp_mib_build(struct snmp_mib *m,const struct statistics_snapshot *s,
                    const struct sensor_snapshot *v,uint64_t now,uint32_t hz,
                    uint32_t uptime_cs,uint32_t links)
{
    static const char *ports[]={"GEM0 right upper","GEM1 right lower",
        "PL0 left upper","PL1 left lower","SFP","CPU"};
#if STATS_DDR
    static const char *ddr[]={"physical ingress write","physical egress read",
        "CPU write","CPU read"};
#endif
#if STATS_DEBUG
    static const char *debug[]={"GEM0 ingress stall","GEM1 ingress stall",
        "PL0 ingress stall","PL1 ingress stall","SFP ingress stall",
        "GEM0 egress stall","GEM1 egress stall","PL0 egress stall",
        "PL1 egress stall","SFP egress stall","CPU to fabric stall",
        "fabric to CPU stall","CPU allocation wait","CPU enqueue wait",
        "link flush busy","combined AXI errors"};
#endif
    m->count=0;
    system_object(m,1,STRING,0,"KR260 open Ethernet switch; R5 FreeRTOS");
    /* sysObjectID: engine encodes the project root for this OID value. */
    system_object(m,2,0x06,0,NULL);
    system_object(m,3,TICKS,uptime_cs,NULL);
    system_object(m,5,STRING,0,"kr260-switch");
    const uint32_t health[]={s->available?1u:2u,s->capabilities,s->polls,
        s->late_polls,s->saturated_reads,s->read_timeouts,
        age(now,s->timestamp,hz),hz,1u|(STATS_DDR<<1)|(STATS_DEBUG<<2)};
    for (unsigned i=0;i<9;i++)
        add(m,1,i+1,0,i==0?INTEGER:(i>=2 && i<=5?COUNTER:GAUGE),health[i],NULL);
    add(m,1,10,0,COUNTER,s->mailbox_release_timeouts,NULL);
    add(m,1,11,0,COUNTER,s->snapshot_response_timeouts,NULL);
    add(m,1,12,0,GAUGE,s->last_release_index,NULL);
    add(m,1,13,0,GAUGE,s->last_release_target_index,NULL);
    add(m,1,14,0,GAUGE,s->last_response_index,NULL);
    for (unsigned col=1;col<=10;col++) for (unsigned row=0;row<6;row++)
        add(m,2,col,row+1,col==1?STRING:col==2?INTEGER:COUNTER64,
            col==1?0:col==2?((links>>row)&1?1:2):s->port[row][col-3],
            col==1?ports[row]:NULL);
#if STATS_DDR
    for (unsigned col=1;col<=9;col++) for (unsigned row=0;row<4;row++)
        add(m,3,col,row+1,col==1?STRING:col==5?GAUGE:COUNTER64,
            col==1?0:s->ddr[row][col-2],col==1?ddr[row]:NULL);
#endif
#if STATS_DEBUG
    for (unsigned col=1;col<=2;col++) for (unsigned row=0;row<16;row++)
        add(m,4,col,row+1,col==1?STRING:COUNTER64,
            col==1?0:s->debug[row],col==1?debug[row]:NULL);
#endif
    add(m,5,1,0,GAUGE,v->valid_mask,NULL);
    add(m,5,2,0,COUNTER,v->errors,NULL);
    add(m,5,3,0,GAUGE,age(now,v->timestamp,hz),NULL);
    for (unsigned i=0;i<2;i++)
        add(m,5,4+i,0,INTEGER,(uint64_t)(int64_t)v->temperature_mc[i],NULL);
    for (unsigned i=0;i<6;i++)
        add(m,5,6+i,0,GAUGE,v->voltage_uv[i/3][i%3],NULL);
    add(m,5,12,0,INTEGER,(uint64_t)(int64_t)v->som_current_ua,NULL);
    add(m,5,13,0,GAUGE,v->som_voltage_uv,NULL);
    add(m,5,14,0,GAUGE,v->som_power_uw,NULL);
    for (unsigned col=1;col<=2;col++) for (unsigned bank=0;bank<13;bank++) {
        if (bank>=8 && bank<12 && !STATS_DDR) continue;
        if (bank==12 && !STATS_DEBUG) continue;
        unsigned slots=bank<4?4:bank==12?16:8;
        for (unsigned slot=0;slot<slots;slot++) {
            add(m,6,col,bank,COUNTER,col==1?s->release_timeout_by_index[bank][slot]:
                s->response_timeout_by_index[bank][slot],NULL);
            struct snmp_object *o=&m->object[m->count-1];
            o->oid.arc[o->oid.length++]=slot;
            o->instance_arcs=2;
        }
    }
}
