/* Packet-level multi-bridge test using the same adapter/library as the R5. */
#include "stp.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
struct node { struct stp_bridge *b; bool fwd[5],learn[5];unsigned flushes,tx0,tx2; };
static struct node nodes[3];
struct endpoint { int node,port; };
static struct endpoint peer[3][5];
struct packet {int src,port;size_t n;uint8_t frame[1514];};
static struct packet queue[4096];static unsigned rd,wr;static uint32_t now;
static void no_loop(void)
{
    int parent[3]={0,1,2};
    for(int i=0;i<3;i++)for(int p=0;p<5;p++) {
        struct endpoint e=peer[i][p];if(e.node<=i || !nodes[i].fwd[p] || !nodes[e.node].fwd[e.port])continue;
        int a=i,b=e.node;while(parent[a]!=a)a=parent[a];while(parent[b]!=b)b=parent[b];
        assert(a!=b && "forwarding loop during state transition");parent[a]=b;
    }
}
static void state(void *ctx,unsigned p,bool l,bool f)
{struct node *n=ctx;n->learn[p]=l;n->fwd[p]=f;no_loop();}
static void flush(void *ctx,unsigned p,bool rapid){(void)p;(void)rapid;((struct node*)ctx)->flushes++;}
static bool tx(void *ctx,unsigned p,const uint8_t *f,size_t n)
{
    struct node *node=ctx;int i=node-nodes;
    assert(n<=1514 && n>=21);if(f[19]==2)node->tx2++;else node->tx0++;
    assert(wr-rd<4096);struct packet *q=&queue[(wr++)%4096];q->src=i;q->port=p;q->n=n;memcpy(q->frame,f,n);return true;
}
static const struct stp_ops ops={state,flush,tx};
static void drain(void)
{
    unsigned count=0;
    while(rd!=wr) {
        assert(++count<10000);struct packet p=queue[(rd++)%4096];struct endpoint e=peer[p.src][p.port];
        if(e.node>=0)stp_rx_bpdu(nodes[e.node].b,e.port,p.frame,p.n,now);
        no_loop();
    }
}
static void run(unsigned seconds)
{for(unsigned t=0;t<seconds;t++){now+=1000;for(unsigned i=0;i<3;i++)stp_tick(nodes[i].b,now);drain();}}
static void wire(int a,int ap,int b,int bp)
{
    peer[a][ap]=(struct endpoint){b,bp};peer[b][bp]=(struct endpoint){a,ap};
    stp_port_link_change(nodes[a].b,ap,true,1000,now);stp_port_link_change(nodes[b].b,bp,true,1000,now);
}
static void unwire(int a,int ap)
{
    struct endpoint e=peer[a][ap];peer[a][ap].node=-1;peer[e.node][e.port].node=-1;
    stp_port_link_change(nodes[a].b,ap,false,0,now);stp_port_link_change(nodes[e.node].b,e.port,false,0,now);
}
static void init(unsigned va,unsigned vb,unsigned vc)
{
    memset(nodes,0,sizeof nodes);rd=wr=now=0;
    for(unsigned i=0;i<3;i++)for(unsigned p=0;p<5;p++)peer[i][p].node=-1;
    unsigned versions[]={va,vb,vc};
    for(unsigned i=0;i<3;i++){uint8_t mac[]={2,0,0,0,0,i+1};nodes[i].b=stp_create(mac,versions[i],&ops,&nodes[i]);assert(nodes[i].b);}
    wire(0,0,1,0);wire(1,1,2,0);wire(2,1,0,1);drain();
}
static void check_tree(void)
{
    struct stp_status s;unsigned forwarding=0;
    for(unsigned i=0;i<3;i++){
        stp_get_status(nodes[i].b,&s);assert(s.is_root==(i==0));assert(s.root_id.mac[5]==1);
        if(i)assert(s.root_port<2 && s.root_path_cost==20000);
        for(unsigned p=0;p<2;p++)forwarding+=nodes[i].fwd[p];
    }
    assert(forwarding==5);no_loop();
}
static void finish(void)
{for(unsigned i=0;i<3;i++)for(unsigned p=0;p<5;p++)peer[i][p].node=-1;for(unsigned i=0;i<3;i++)stp_destroy(nodes[i].b);}
int main(void)
{
    init(2,2,2);run(3);check_tree();
    assert(nodes[0].tx2 && nodes[1].tx2 && nodes[2].tx2);
    unsigned flushes=nodes[0].flushes+nodes[1].flushes+nodes[2].flushes;
    unwire(0,0);drain();run(3);
    assert(nodes[0].fwd[1] && nodes[2].fwd[1] && nodes[2].fwd[0] && nodes[1].fwd[1]);
    assert(nodes[0].flushes+nodes[1].flushes+nodes[2].flushes>flushes);
    wire(0,0,1,0);drain();run(3);check_tree();
    /* Truncated/foreign LLC/invalid declared length must not enter engine. */
    uint8_t bad[60]={0};struct stp_status before,after;stp_get_status(nodes[0].b,&before);
    for(unsigned n=0;n<60;n++)assert(!stp_rx_bpdu(nodes[0].b,0,bad,n,now));
    memcpy(bad,"\x01\x80\xc2\0\0\0",6);bad[6]=2;bad[14]=bad[15]=0x42;bad[16]=3;bad[13]=100;
    assert(!stp_rx_bpdu(nodes[0].b,0,bad,60,now));
    stp_get_status(nodes[0].b,&after);assert(before.port[0].bpdu_rx==after.port[0].bpdu_rx);
    finish();
    init(0,0,0);run(3);assert(!nodes[0].fwd[0]);run(45);check_tree();finish();
    init(0,2,2);run(50);check_tree();assert(nodes[0].tx0 && nodes[1].tx2 && nodes[2].tx2);finish();
    puts("PASS: RSTP triangle converges in <=3s, no transient forwarding loops, link failure/recovery, FDB flushes, malformed frames, classic and mixed STP interoperability");
}
