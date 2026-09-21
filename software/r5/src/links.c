#include "board.h"
#include "policy.h"
#include "FreeRTOS.h"
#include "task.h"
#include "xil_printf.h"
#define GEM0 0xff0b0000UL
#define GEM1 0xff0c0000UL
static bool ps_ready[2];
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
static bool phy_init(unsigned port)
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
    /* This first firmware supports only 1000BASE-T full duplex. */
    if (!phy_write(phy,4,1) || !phy_write(phy,9,0x0200)) return false;
    return phy_write(phy,0,0x1200); /* enable and restart autonegotiation */
}
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
        if (!ps_ready[i]) ps_ready[i]=phy_init(i);
        bool valid=ps_ready[i] && mdio(phy,0x11,false,&status);
        if (!valid) ps_ready[i]=false;
        bool link=valid && (status&0xe400u)==0xa400u;
        if (link) up |= 1u<<i;
        mmio_write((i?GEM1:GEM0),link?0x1cu:0x10u);
    }
    uint32_t calibrated=mmio_read(DIAG_BASE);
    for (unsigned i=0;i<2;i++) {
        /* Hardware owns PL MDIO and continuously polls PHYSTS. Read its
         * completed, validity-qualified snapshot; never contend with it. */
        uint32_t status=mmio_read(0x80010010UL+i*0x10000UL);
        if ((status&0x3f8u)==0x3a8u && (calibrated&(1u<<(4+i)))) up |= 1u<<(i+2);
    }
    uint32_t sb=mmio_read(DIAG_BASE+4), pcs=mmio_read(DIAG_BASE+PCS_STATUS);
    if (!(sb&0x1fu) && (pcs&0xfu)==7u) up |= 0x10;
    *mask=up; return true;
}
void board_link_task(void *unused)
{
    (void)unused; mac_init();
    struct link_policy state={0,0};
    TickType_t wake=xTaskGetTickCount();
    for (;;) {
        uint8_t desired; board_phy_mask(&desired);
        if (!fabric_dma_healthy()) desired=0;
        struct link_action a=link_update(&state,desired,
            (mmio_read(DIAG_BASE+LINK_STATUS)&0x100u)!=0,
            (uint32_t)(xTaskGetTickCount()*portTICK_PERIOD_MS));
        if (a.clear) mmio_write(DIAG_BASE+LINK_CLR,a.clear);
        if (a.set) mmio_write(DIAG_BASE+LINK_SET,a.set);
        if (a.clear || a.set) xil_printf("Fabric physical links: %02x\r\n",state.enabled);
        network_link_changed(state.enabled!=0);
        vTaskDelayUntil(&wake,pdMS_TO_TICKS(250));
    }
}
