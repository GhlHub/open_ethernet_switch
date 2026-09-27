#include "board.h"
#include "policy.h"
#include "FreeRTOS.h"
#include "task.h"
#include "xil_printf.h"
#define GEM0 0xff0b0000UL
#define GEM1 0xff0c0000UL
static bool ps_ready[2], pl_ready[2];
static struct port_snapshot ports={.admin=PHYSICAL_PORT_MASK,
    .advertise={4,PS_ADV_ALL,PS_ADV_ALL,PS_ADV_ALL}};
static uint16_t configured_speed[4];
static struct link_policy link_state;
void board_ports_snapshot(struct port_snapshot *out)
{
    taskENTER_CRITICAL(); *out=ports; taskEXIT_CRITICAL();
}
bool board_ports_configure(uint8_t mask,const uint8_t advertise[4])
{
    if (mask>PHYSICAL_PORT_MASK || (advertise &&
        (advertise[0]!=4 || !advertise[1] || advertise[1]>7 ||
         !advertise[2] || advertise[2]>7 || !advertise[3] || advertise[3]>7))) return false;
    taskENTER_CRITICAL();
    ports.admin=mask;
    if (advertise) for (unsigned i=0;i<4;i++) ports.advertise[i]=advertise[i];
    taskEXIT_CRITICAL(); return true;
}
void board_ports_set(uint8_t mask) { (void)board_ports_configure(mask,NULL); }
void board_ports_get(uint8_t *admin,uint8_t *physical,uint8_t *forwarding)
{
    struct port_snapshot p; board_ports_snapshot(&p);
    *admin=p.admin; *physical=p.physical; *forwarding=p.forwarding;
}
/* Verified on the development carrier by DP83867 ID reads (2000:a231).
 * GEM1 responds at address 9, not the previously assumed address 8. */
static const unsigned ps_phy_addr[2]={4,9};
/* Both carrier PS PHYs share GEM1's MIO50/51 MDIO bus. */
static bool mdio(unsigned phy,unsigned reg,bool write,uint16_t *value)
{
    uint64_t start=board_timestamp(), limit=board_timestamp_hz()/100u;
    while (!(mmio_read(GEM1+8)&4u))
        if (board_timestamp()-start>limit) return false;
    mmio_write(GEM1+0x34,0x40020000u | (write?0x10000000u:0x20000000u) |
               (phy<<23) | (reg<<18) | (write?*value:0));
    start=board_timestamp();
    while (!(mmio_read(GEM1+8)&4u))
        if (board_timestamp()-start>limit) return false;
    if (!write) *value=(uint16_t)mmio_read(GEM1+0x34);
    return write || *value!=0xffffu;
}
static bool phy_write(unsigned phy,unsigned reg,uint16_t value) { return mdio(phy,reg,true,&value); }
static bool mmd(unsigned phy,unsigned reg,bool write,uint16_t *value)
{
    return phy_write(phy,13,0x1f) && phy_write(phy,14,(uint16_t)reg) &&
           phy_write(phy,13,0x401f) && mdio(phy,14,write,value);
}
static bool phy_init(unsigned port,unsigned advertise)
{
    unsigned phy=ps_phy_addr[port]; uint16_t id1,id2,v;
    if (!mdio(phy,2,false,&id1) || !mdio(phy,3,false,&id2) ||
        id1!=0x2000 || (id2&0xfff0)!=0xa230) return false;
    /* Board straps select SGMII on GEM0. Preserve strap-selected mode. */
    if (port) {
        if (!mmd(phy,0x31,false,&v)) return false;
        v &= (uint16_t)~0x80u;
        if (!mmd(phy,0x31,true,&v) || !mmd(phy,0x32,false,&v)) return false;
        v |= 3;
        if (!mmd(phy,0x32,true,&v)) return false;
        v=0x67; /* 1.75 ns TX / 2.00 ns RX; validate on carrier */
        if (!mmd(phy,0x86,true,&v)) return false;
    }
    /* Never advertise half duplex or pause; copper AN remains enabled. */
    if (!phy_write(phy,4,ps_phy_advertisement(advertise)) ||
        !phy_write(phy,9,(advertise&4u)?0x0200u:0)) return false;
    return phy_write(phy,0,0x1200); /* enable and restart autonegotiation */
}
/* Pause new hardware polls before issuing CPU MDIO transactions. The current
 * poll completes normally; STATUS.DONE then belongs to the CPU until release. */
static bool pl_wait(uintptr_t base,bool done)
{
    uint64_t start=board_timestamp(),limit=board_timestamp_hz()/100u;
    do {
        uint32_t s=mmio_read(base+0x10);
        if (done ? (s&2u)!=0 : (s&1u)==0) return !done || !(s&4u);
    } while (board_timestamp()-start<=limit);
    return false;
}
static bool pl_write(uintptr_t base,unsigned phy,unsigned reg,uint16_t value)
{
    if (!pl_wait(base,false)) return false;
    mmio_write(base+0x10,6); /* clear CPU DONE/ERROR */
    mmio_write(base,(1u<<16)|(reg<<8)|phy);
    mmio_write(base+4,value); mmio_write(base+0x0c,1);
    return pl_wait(base,true);
}
static bool pl_advertise(unsigned port,unsigned capabilities)
{
    uintptr_t base=0x80010000UL+port*0x10000UL;
    if ((mmio_read(base+0x10)&0x18u)!=8u) return false;
    mmio_write(base+0x18,1);
    bool ok=pl_wait(base,false) &&
        pl_write(base,port+2,4,ps_phy_advertisement(capabilities)) &&
        pl_write(base,port+2,9,(capabilities&4u)?0x200u:0) &&
        pl_write(base,port+2,0,0x1200);
    mmio_write(base+0x18,0);
    return ok;
}
static uintptr_t pl_mac(unsigned i) { return 0x80040000UL+i*0x40000UL; }
static uint32_t pl_mode(unsigned speed) {return speed==1000?2u:speed==100?1u:0u;}
static void mac_init(void)
{
    /* The GEM FIFO shims run on the PS clock routed through a PL BUFG and
     * looped back into PS8. Select that same clock for the PS FIFO interface;
     * the generated psu_init leaves these selects at their internal default.
     * Change the selection before enabling either MAC (UG1087 GEM_CLK_CTRL). */
    mmio_write(GEM0,0x10);
    mmio_write(GEM1,0x10);
    mmio_write(0xff180308UL,mmio_read(0xff180308UL)|0x108u);
    const uintptr_t macs[]={0x80040000UL,0x80080000UL,0x800c0000UL};
    for (unsigned i=0;i<3;i++) {
        mmio_write(macs[i]+0x14,0); /* poll only; no MAC interrupts */
        mmio_write(macs[i]+0x410,0x80000000u); /* gigabit */
        if (i<2) mmio_write(macs[i]+0x41c,2); /* port disabled until configured */
        mmio_write(macs[i]+0x404,0x12000000u); /* RX enable */
        mmio_write(macs[i]+0x408,0x10000000u); /* TX enable */
    }
    for (unsigned i=0;i<2;i++) {
        uintptr_t gem=i?GEM1:GEM0;
        mmio_write(gem,0x10); /* MDIO only until supported link */
        mmio_write(gem+0x2c,UINT32_MAX); /* mask interrupts */
        /* MDC /224; copy all, remove FCS, full duplex, 1G. */
        uint32_t cfg=(7u<<18)|0x20000u|0x400u|0x10u|2u;
        if (!i) cfg |= 0x08000800u; /* SGMII + PCS */
        mmio_write(gem+4,cfg);
        mmio_write(gem+0x4c,1); /* external FIFO: never start GEM DMA */
    }
}
bool board_phy_mask(uint8_t *mask)
{
    uint8_t up=0;
    for (unsigned i=0;i<2;i++) {
        uint16_t status=0; unsigned phy=ps_phy_addr[i];
                bool valid=ps_ready[i] && mdio(phy,0x11,false,&status);
        if (!valid) ps_ready[i]=false;
        ports.speed_mbps[i]=valid?ps_phy_speed(status):0;
        unsigned ability=ports.speed_mbps[i]==1000?4:ports.speed_mbps[i]==100?2:1;
        if (!(ports.applied[i]&ability)) ports.speed_mbps[i]=0;
        if (ports.speed_mbps[i]) up |= 1u<<i;
    }
    uint32_t calibrated=mmio_read(DIAG_BASE);
    for (unsigned i=0;i<2;i++) {
        /* Hardware publishes a completed, validity-qualified link snapshot. */
        uint32_t status=mmio_read(0x80010010UL+i*0x10000UL);
        unsigned speed=((status>>6)&3u)==2?1000:((status>>6)&3u)==1?100:((status>>6)&3u)==0?10:0;
        unsigned ability=speed==1000?4:speed==100?2:1;
        bool valid=pl_ready[i] && (status&0x738u)==0x728u &&
                   (calibrated&(1u<<(4+i))) && (ports.applied[i+2]&ability);
        ports.speed_mbps[i+2]=valid?(uint16_t)speed:0;
        if (ports.speed_mbps[i+2]) up |= 1u<<(i+2);
    }
    uint32_t sb=mmio_read(DIAG_BASE+4), pcs=mmio_read(DIAG_BASE+PCS_STATUS);
    if (!(sb&0x1fu) && (pcs&0xfu)==7u) up |= 0x10;
    ports.speed_mbps[4]=(up&0x10)?1000:0;
    *mask=up; return true;
}
/* Single owner of all MAC/PHY changes. Called at 250 ms intervals. */
static void link_poll(void)
{
    struct port_snapshot request; board_ports_snapshot(&request);
    uint8_t observed; board_phy_mask(&observed);
    uint8_t desired=observed & request.admin;
    uint32_t now=(uint32_t)(xTaskGetTickCount()*portTICK_PERIOD_MS);
    bool busy=(mmio_read(DIAG_BASE+LINK_STATUS)&0x100u)!=0;
    for (unsigned i=0;i<2;i++) {
        bool change=!ps_ready[i] || ports.applied[i]!=request.advertise[i] ||
                    configured_speed[i]!=ports.speed_mbps[i];
        if (change) desired &= (uint8_t)~(1u<<i);
        /* Quiesce before queue flush, clock changes or PHY restart. */
        mmio_write(i?GEM1:GEM0,(desired&(1u<<i))?0x1cu:0x10u);
    }
    for (unsigned i=0;i<2;i++) {
        unsigned p=i+2;
        bool change=!pl_ready[i] || ports.applied[p]!=request.advertise[p] ||
                    configured_speed[p]!=ports.speed_mbps[p];
        if (change) desired &= (uint8_t)~(1u<<p);
        mmio_write(pl_mac(i)+0x41c,pl_mode(configured_speed[p])|((desired&(1u<<p))?4u:0u));
    }
    const uintptr_t macs[]={0x80040000UL,0x80080000UL,0x800c0000UL};
    for (unsigned i=0;i<3;i++)
        mmio_write(macs[i]+0x404,(request.admin&(1u<<(i+2)))?0x12000000u:0x02000000u);
    if (!fabric_dma_healthy()) desired=0;
    struct link_action a=link_update(&link_state,desired,busy,now);
    if (a.clear) mmio_write(DIAG_BASE+LINK_CLR,a.clear);
    if (a.set) mmio_write(DIAG_BASE+LINK_SET,a.set);
    if (a.clear || a.set) xil_printf("Fabric physical links: %02x\r\n",link_state.enabled);
    /* Wait at least one polling interval after removal, and for flush idle.
     * Reconfigured ports cannot be added until a later poll. */
    if (!busy && (uint32_t)(now-link_state.last_clear_ms)>=250u) {
        for (unsigned i=0;i<2;i++) if (!(link_state.enabled&(1u<<i))) {
            if (!ps_ready[i] || ports.applied[i]!=request.advertise[i]) {
                ps_ready[i]=phy_init(i,request.advertise[i]);
                if (ps_ready[i]) ports.applied[i]=request.advertise[i];
                configured_speed[i]=0; ports.speed_mbps[i]=0;
                observed &= (uint8_t)~(1u<<i);
            } else if (configured_speed[i]!=ports.speed_mbps[i]) {
                unsigned speed=ports.speed_mbps[i];
                if (speed) {
                    uintptr_t ref=0xff5e0050UL+i*4, gem=i?GEM1:GEM0;
                    if (i) mmio_write(ref,ps_gem_clock(mmio_read(ref),speed));
                    mmio_write(gem+4,ps_gem_config(mmio_read(gem+4),speed));
                    xil_printf("GEM%u: %u Mb/s full duplex\r\n",i,speed);
                }
                configured_speed[i]=(uint16_t)speed;
            }
        }
    }
    if (!busy && (uint32_t)(now-link_state.last_clear_ms)>=250u) {
        for (unsigned i=0;i<2;i++) {
            unsigned p=i+2;
            if (link_state.enabled&(1u<<p)) continue;
            if (!pl_ready[i] || ports.applied[p]!=request.advertise[p]) {
                pl_ready[i]=pl_advertise(i,request.advertise[p]);
                if (pl_ready[i]) ports.applied[p]=request.advertise[p];
                configured_speed[p]=0; ports.speed_mbps[p]=0;
                observed &= (uint8_t)~(1u<<p);
            } else if (configured_speed[p]!=ports.speed_mbps[p]) {
                unsigned speed=ports.speed_mbps[p];
                mmio_write(pl_mac(i)+0x41c,pl_mode(speed)); /* disabled while mode settles */
                configured_speed[p]=(uint16_t)speed;
                if (speed) xil_printf("PL%u: %u Mb/s full duplex\r\n",i,speed);
            }
        }
    }
    ports.physical=observed; ports.forwarding=link_state.enabled;
    network_link_changed(link_state.enabled!=0);
}
void board_link_task(void *unused)
{
    (void)unused; mac_init();
    /* Divisors below assume the checked-in 1 GHz integer IOPLL preset. */
    for (unsigned i=0;i<2;i++)
        configASSERT((mmio_read(0xff5e0050UL+i*4)&0x003f3f07u)==0x00010800u);
    TickType_t wake=xTaskGetTickCount();
    for (;;) {link_poll();vTaskDelayUntil(&wake,pdMS_TO_TICKS(250));}
}
