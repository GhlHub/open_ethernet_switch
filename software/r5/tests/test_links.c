/* Run the actual link service with a register-level MDIO/clock model. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../src/links.c"
void pstate_link_clear(uint8_t mask){mmio_write(DIAG_BASE+LINK_CLR,mask);}
static uint32_t ticks, maint;
static uint16_t phy[32][32];
static struct {uintptr_t addr;uint32_t value;} regs[64];
static unsigned nregs;
static unsigned restarts[32];
uint32_t mmio_read(uintptr_t a)
{
    if(a==GEM1+8)return 4;
    if(a==GEM1+0x34)return maint;
    for(unsigned i=0;i<nregs;i++)if(regs[i].addr==a)return regs[i].value;
    return 0;
}
static void set_reg(uintptr_t a,uint32_t v)
{
    for(unsigned i=0;i<nregs;i++)if(regs[i].addr==a){regs[i].value=v;return;}
    assert(nregs<64);regs[nregs].addr=a;regs[nregs++].value=v;
}
static bool pl_command_error;
void mmio_write(uintptr_t a,uint32_t v)
{
    if(a==GEM1+0x34){
        unsigned p=(v>>23)&31,r=(v>>18)&31;
        if((v&0x30000000)==0x10000000){phy[p][r]=(uint16_t)v;if(r==0){restarts[p]++;phy[p][17]=0;}}
        else maint=phy[p][r];
        return;
    }
    if(a>=0x80010000 && a<0x80030000){
        uintptr_t base=a&~0xffffUL;unsigned off=a-base;
        if(off==0x10){set_reg(a,mmio_read(a)&~(v&6));return;}
        if(off==0x0c && (v&1)){
            assert(mmio_read(base+0x18)==1); /* exclusive CPU ownership */
            unsigned cfg=mmio_read(base),p=cfg&31,r=(cfg>>8)&31;
            assert(cfg&(1u<<16));
            if(!pl_command_error){phy[p][r]=(uint16_t)mmio_read(base+4);
                if(r==0){restarts[p]++;set_reg(base+0x10,8);}}
            set_reg(base+0x10,mmio_read(base+0x10)|2|(pl_command_error?4:0));return;
        }
    }
    set_reg(a,v);
}
uint64_t board_timestamp(void){static uint64_t t;return ++t;}
uint32_t board_timestamp_hz(void){return 781250;}
TickType_t xTaskGetTickCount(void){return ticks;}
void vTaskDelayUntil(TickType_t *a,TickType_t b){*a+=b;}
bool fabric_dma_healthy(void){return true;}
void network_link_changed(bool up){(void)up;}
int xil_printf(const char *s,...){(void)s;return 0;}
static void poll(void){ticks+=250;link_poll();}
int main(void)
{
    phy[4][2]=phy[9][2]=0x2000;phy[4][3]=phy[9][3]=0xa231;
    mmio_write(0xff5e0050,0x06010800);mmio_write(0xff5e0054,0x06010800);
    mmio_write(DIAG_BASE+PCS_STATUS,7);mac_init();poll();
    assert(ports.speed_mbps[4]==1000);
    set_reg(0x800c04f8UL,0x31304745u);poll();
    assert(ports.speed_mbps[4]==10000);
    set_reg(DIAG_BASE+PCS_STATUS,0);poll();assert(ports.speed_mbps[4]==0);
    set_reg(DIAG_BASE+PCS_STATUS,7);poll();assert(ports.speed_mbps[4]==10000);
    set_reg(0x800c04f8UL,0);poll();assert(ports.speed_mbps[4]==1000);
    assert(phy[4][4]==1 && phy[9][4]==0x141 && phy[4][9]==0x200);
    phy[4][17]=phy[9][17]=0xac00;poll();poll();
    assert(ports.forwarding==19 && configured_speed[0]==1000);
    uint8_t adv[]={4,2,7,7};assert(board_ports_configure(31,adv));poll();
    assert(ports.forwarding==17 && restarts[9]==1 && mmio_read(GEM1)==0x10);
    mmio_write(DIAG_BASE+LINK_STATUS,0x100);poll();assert(restarts[9]==1);
    mmio_write(DIAG_BASE+LINK_STATUS,0);poll();
    assert(restarts[4]==1 && phy[4][4]==1 && phy[4][9]==0x200);
    assert(phy[9][4]==0x101 && phy[9][9]==0);
    phy[4][17]=0xac00;phy[9][17]=0x6c00;poll();
    assert(mmio_read(0xff5e0050)==0x06010800 && mmio_read(0xff5e0054)==0x06050800);
    assert((mmio_read(GEM0+4)&0x403)==0x402 && (mmio_read(GEM1+4)&0x403)==3);
    assert(ports.forwarding==17);poll();assert(ports.forwarding==19);
    phy[4][17]=0x0c00;poll();assert(!(ports.forwarding&1)); /* Half duplex */
    phy[4][17]=0xec00;poll();assert(!ports.speed_mbps[0]); /* Reserved speed */
    phy[4][17]=0x2c00;poll();assert(!ports.speed_mbps[0]); /* Not supported in PS SGMII */
    adv[1]=1;assert(board_ports_configure(31,adv));poll();poll();
    phy[9][17]=0x2c00;poll();poll();
    assert(configured_speed[1]==10 && mmio_read(0xff5e0054)==0x06320800);
    adv[0]=4;adv[1]=7;assert(board_ports_configure(31,adv));poll();poll();
    phy[4][17]=phy[9][17]=0xac00;poll();poll();
    assert(ports.forwarding==19 && mmio_read(0xff5e0050)==0x06010800);
    unsigned count=restarts[4];poll();assert(restarts[4]==count);
    board_ports_set(30);poll();assert(ports.speed_mbps[0]==1000 && !(ports.forwarding&1));
    adv[0]=0;assert(!board_ports_configure(31,adv));assert(ports.admin==30);
    assert(ps_phy_speed(0xa400)==0); /* Unresolved */
    for(unsigned a=1;a<=7;a++)assert(!(ps_phy_advertisement(a)&0x2a0));
    /* PL ports: startup, all rates, independent advertisement, flush gating. */
    mmio_write(DIAG_BASE,0x30);
    set_reg(0x80010010,8);set_reg(0x80020010,8);
    adv[0]=4;adv[1]=7;adv[2]=7;adv[3]=7;
    assert(board_ports_configure(31,adv));poll();
    assert(phy[2][4]==0x141 && phy[3][9]==0x200);
    set_reg(0x80010010,0x7a8);set_reg(0x80020010,0x7a8);poll();poll();
    assert(configured_speed[2]==1000 && configured_speed[3]==1000);
    assert((ports.forwarding&12)==12);
    for(unsigned port=0;port<2;port++)for(int code=1;code>=0;code--){
        unsigned idx=port+2;uintptr_t base=0x80010000UL+port*0x10000UL;
        adv[idx]=1u<<code;assert(board_ports_configure(31,adv));poll();
        assert(!(ports.forwarding&(1u<<idx)) && !(mmio_read(pl_mac(port)+0x41c)&4));
        unsigned n=restarts[idx];mmio_write(DIAG_BASE+LINK_STATUS,0x100);poll();
        assert(restarts[idx]==n);mmio_write(DIAG_BASE+LINK_STATUS,0);poll();
        assert(phy[idx][4]==ps_phy_advertisement(adv[idx]) && phy[idx][9]==0);
        assert(mmio_read(base+0x18)==0);
        set_reg(base+0x10,0x728|(code<<6));poll();
        assert(configured_speed[idx]==(code?100:10) && !(ports.forwarding&(1u<<idx)));
        poll();assert(ports.forwarding&(1u<<idx));
        assert(mmio_read(pl_mac(port)+0x41c)==(4u|(unsigned)code));
        set_reg(base+0x10,0x628|(code<<6));poll(); /* half duplex */
        assert(!ports.speed_mbps[idx] && !(ports.forwarding&(1u<<idx)));
        set_reg(base+0x10,0x328|(code<<6));poll(); /* unresolved */
        assert(!ports.speed_mbps[idx]);
    }
    adv[2]=7;pl_command_error=true;assert(board_ports_configure(31,adv));poll();poll();
    assert(!pl_ready[0] && mmio_read(0x80010018)==0 && !(ports.forwarding&4));
    pl_command_error=false;poll();assert(pl_ready[0]);
    /* Dual mode is requested only after SFP forwarding is removed and flush
     * completes; Auto does not disturb a working link. */
    set_reg(SFP_BASE+0x4f8,SFP_DUAL_ID);set_reg(SFP_BASE+0x4f0,10000);
    set_reg(SFP_BASE+0x4e4,11);set_reg(DIAG_BASE+PCS_STATUS,7);
    set_reg(DIAG_BASE+4,0);board_sfp_configure(1000);
    set_reg(DIAG_BASE+LINK_STATUS,0x100);poll();
    assert(sfp_pending && !(ports.forwarding&16));
    set_reg(SFP_BASE+0x4e0,99);poll();assert(mmio_read(SFP_BASE+0x4e0)==99);
    set_reg(DIAG_BASE+LINK_STATUS,0);poll();
    assert(!sfp_pending && mmio_read(SFP_BASE+0x4e0)==0);
    set_reg(SFP_BASE+0x4f0,1000);set_reg(SFP_BASE+0x4e4,10);poll();poll();
    assert(ports.speed_mbps[4]==1000);
    board_sfp_configure(0);poll();poll();assert(sfp_target==10000);
    set_reg(SFP_BASE+0x4f0,10000);set_reg(SFP_BASE+0x4e4,11);
    for(unsigned i=0;i<24;i++){poll();}assert(sfp_target==10000);
    set_reg(DIAG_BASE+PCS_STATUS,0);for(unsigned i=0;i<17;i++){poll();}
    assert(sfp_target==1000 && mmio_read(SFP_BASE+0x4e0)==0);
    set_reg(DIAG_BASE+4,1);for(unsigned i=0;i<24;i++){poll();}assert(sfp_target==1000);
    assert(board_sfp_capabilities()==3);
    puts("PASS: dual SFP forced rate, flush ordering, stable-link Auto, missing-link probing and absent-module hold");
    puts("PASS: PL full-duplex speeds, MDIO ownership/error recovery, advertisements and quiesce/flush");
    puts("PASS: PS full-duplex negotiation, advertised subsets, quiesce/flush, clock/speed changes, half-duplex rejection and admin state");
}
