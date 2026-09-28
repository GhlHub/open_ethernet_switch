/* Platform-neutral adapter to the pinned Apache-2.0 mstp-lib engine. */
#include "stp.h"
#include "../../../third_party/mstp-lib/mstp-lib/stp.h"
#include <stdlib.h>
#include <string.h>
struct stp_bridge {
    struct STP_BRIDGE *engine;
    struct stp_ops ops;
    void *context;
    struct stp_status status;
    bool learning[STP_NUM_PORTS],forwarding[STP_NUM_PORTS];
    uint8_t tx[1514]; unsigned tx_port; size_t tx_size;
};
static struct stp_bridge *owner(const struct STP_BRIDGE *b){return STP_GetApplicationContext(b);}
static void trapping(const struct STP_BRIDGE *b,bool enable,unsigned t){(void)b;(void)enable;(void)t;}
static void learning(const struct STP_BRIDGE *e,unsigned p,unsigned tree,bool enable,unsigned t)
{
    (void)tree;(void)t;struct stp_bridge *b=owner(e);b->learning[p]=enable;
    b->ops.state(b->context,p,enable,b->forwarding[p]);
}
static void forwarding(const struct STP_BRIDGE *e,unsigned p,unsigned tree,bool enable,unsigned t)
{
    (void)tree;(void)t;struct stp_bridge *b=owner(e);b->forwarding[p]=enable;
    b->ops.state(b->context,p,b->learning[p],enable);
}
static void *tx_get(const struct STP_BRIDGE *e,unsigned p,unsigned n,unsigned t)
{
    (void)t;struct stp_bridge *b=owner(e);if(n>sizeof(b->tx)-17)return NULL;
    memset(b->tx,0,sizeof(b->tx));memcpy(b->tx,"\x01\x80\xc2\0\0\0",6);
    memcpy(b->tx+6,b->status.bridge_id.mac,6);b->tx[12]=(n+3)>>8;b->tx[13]=n+3;
    b->tx[14]=b->tx[15]=0x42;b->tx[16]=3;b->tx_port=p;b->tx_size=n+17;
    return b->tx+17;
}
static void tx_release(const struct STP_BRIDGE *e,void *buffer)
{
    (void)buffer;struct stp_bridge *b=owner(e);
    if(b->ops.transmit(b->context,b->tx_port,b->tx,b->tx_size)) b->status.port[b->tx_port].bpdu_tx++;
    else b->status.tx_failed++;
}
static void flush(const struct STP_BRIDGE *e,unsigned p,unsigned tree,enum STP_FLUSH_FDB_TYPE type,unsigned t)
{(void)tree;(void)t;struct stp_bridge *b=owner(e);b->ops.flush(b->context,p,type==STP_FLUSH_FDB_TYPE_RAPID_AGEING);}
static void changed(const struct STP_BRIDGE *e,unsigned tree,unsigned t)
{(void)tree;(void)t;owner(e)->status.topology_change_count++;}
static void role(const struct STP_BRIDGE *e,unsigned p,unsigned tree,enum STP_PORT_ROLE r,unsigned t)
{(void)tree;(void)r;(void)t;owner(e)->status.port[p].role_changes++;}
#ifdef __FREERTOS__
#include "FreeRTOS.h"
static void *allocate(unsigned n){void *p=pvPortMalloc(n);if(p)memset(p,0,n);return p;}
static void release(void *p){vPortFree(p);}
#else
static void *allocate(unsigned n){return calloc(1,n);}
static void release(void *p){free(p);}
#endif
static const struct STP_CALLBACKS callbacks={trapping,learning,forwarding,tx_get,tx_release,flush,NULL,changed,role,allocate,release};
struct stp_bridge *stp_create(const uint8_t mac[6],uint8_t version,const struct stp_ops *ops,void *context)
{
    if(version!=STP_CLASSIC && version!=STP_RAPID)return NULL;
    struct stp_bridge *b=allocate(sizeof(*b));if(!b)return NULL;
    b->ops=*ops;b->context=context;b->status.enabled=true;b->status.version=version;
    b->status.bridge_id.priority=32768;memcpy(b->status.bridge_id.mac,mac,6);
    b->engine=STP_CreateBridge(STP_NUM_PORTS,0,0,&callbacks,mac,0);
    if(!b->engine){release(b);return NULL;}
    STP_SetApplicationContext(b->engine,b);
    STP_SetStpVersion(b->engine,(enum STP_VERSION)version,0);
    /* Require real protocol handshakes/timers; never infer an edge port from
     * silence. No user-configurable edge ports in this initial integration. */
    for(unsigned p=0;p<STP_NUM_PORTS;p++)STP_SetPortAutoEdge(b->engine,p,false,0);
    STP_StartBridge(b->engine,0);return b;
}
void stp_destroy(struct stp_bridge *b)
{if(b){STP_StopBridge(b->engine,0);STP_DestroyBridge(b->engine);release(b);}}
void stp_port_link_change(struct stp_bridge *b,unsigned p,bool up,uint16_t speed,uint32_t now)
{
    if(p>=STP_NUM_PORTS)return;
    if(STP_GetPortEnabled(b->engine,p))STP_OnPortDisabled(b->engine,p,now);
    if(up)STP_OnPortEnabled(b->engine,p,speed,true,now); /* supported PHY links are full duplex */
}
void stp_tick(struct stp_bridge *b,uint32_t now){STP_OnOneSecondTick(b->engine,now);}
bool stp_rx_bpdu(struct stp_bridge *b,unsigned p,const uint8_t *f,size_t n,uint32_t now)
{
    if(p>=STP_NUM_PORTS || !STP_GetPortEnabled(b->engine,p) || n<21 || n>1514 ||
       memcmp(f,"\x01\x80\xc2\0\0\0",6) || (f[6]&1) ||
       !memcmp(f+6,"\0\0\0\0\0\0",6) || f[14]!=0x42 || f[15]!=0x42 || f[16]!=3)return false;
    unsigned length=((unsigned)f[12]<<8)|f[13];
    if(length<7 || length>1500 || length>n-14 || f[17] || f[18])return false;
    unsigned bpdu=length-3;
    if(f[20]==0x80) {if(f[19]!=0 || bpdu<4)return false;b->status.tcn_rx++;}
    else if(f[20]==0) {if(f[19]!=0 || bpdu<35)return false;}
    else if(f[20]==2) {if(f[19]<2 || bpdu<36)return false;}
    else return false;
    b->status.port[p].bpdu_rx++;
    STP_OnBpduReceived(b->engine,p,f+17,bpdu,now);return true;
}
void stp_get_status(const struct stp_bridge *b,struct stp_status *out)
{
    *out=b->status;uint8_t v[36];STP_GetRootPriorityVector(b->engine,0,v);
    out->root_id.priority=((uint16_t)v[0]<<8)|v[1];memcpy(out->root_id.mac,v+2,6);
    out->root_path_cost=((uint32_t)v[8]<<24)|((uint32_t)v[9]<<16)|((uint32_t)v[10]<<8)|v[11];
    unsigned pid=((unsigned)v[34]<<8)|v[35];out->root_port=(pid&4095)?(pid&4095)-1:STP_ROOT_NONE;
    out->is_root=STP_IsCistRoot(b->engine);
    for(unsigned p=0;p<STP_NUM_PORTS;p++) {
        struct stp_port_status *s=&out->port[p];
        enum STP_PORT_ROLE r=STP_GetPortRole(b->engine,p,0);
        s->role=r==STP_PORT_ROLE_ROOT?STP_ROLE_ROOT:r==STP_PORT_ROLE_DESIGNATED?STP_ROLE_DESIGNATED:
            r==STP_PORT_ROLE_BACKUP?STP_ROLE_BACKUP:r==STP_PORT_ROLE_ALTERNATE?STP_ROLE_BLOCKING:STP_ROLE_DISABLED;
        s->link_up=STP_GetPortEnabled(b->engine,p);
        s->state=!s->link_up?STP_STATE_DISABLED:b->forwarding[p]?STP_STATE_FORWARDING:
            b->learning[p]?STP_STATE_LEARNING:STP_STATE_BLOCKING;
        s->path_cost=STP_GetExternalPortPathCost(b->engine,p);
    }
}
