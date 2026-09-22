/* Run the actual link service with a register-level MDIO/clock model. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../src/links.c"
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
void mmio_write(uintptr_t a,uint32_t v)
{
    if(a==GEM1+0x34){
        unsigned p=(v>>23)&31,r=(v>>18)&31;
        if((v&0x30000000)==0x10000000){phy[p][r]=(uint16_t)v;if(r==0){restarts[p]++;phy[p][17]=0;}}
        else maint=phy[p][r];
        return;
    }
    for(unsigned i=0;i<nregs;i++)if(regs[i].addr==a){regs[i].value=v;return;}
    assert(nregs<64);regs[nregs].addr=a;regs[nregs++].value=v;
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
    assert(phy[4][4]==1 && phy[9][4]==0x141 && phy[4][9]==0x200);
    phy[4][17]=phy[9][17]=0xac00;poll();poll();
    assert(ports.forwarding==19 && configured_speed[0]==1000);
    uint8_t adv[]={4,2};assert(board_ports_configure(31,adv));poll();
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
    puts("PASS: PS full-duplex negotiation, advertised subsets, quiesce/flush, clock/speed changes, half-duplex rejection and admin state");
}
