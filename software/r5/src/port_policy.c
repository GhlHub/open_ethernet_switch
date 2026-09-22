#include "ports.h"
unsigned ps_phy_speed(uint16_t status)
{
    /* DP83867 PHYSTS: link, speed/duplex resolved, full duplex required. */
    if ((status&0x2c00u)!=0x2c00u) return 0;
    switch ((status>>14)&3u) {case 0:return 10;case 1:return 100;case 2:return 1000;default:return 0;}
}
uint16_t ps_phy_advertisement(unsigned capabilities)
{
    /* IEEE selector + full-duplex abilities only; no pause or half duplex. */
    return 1u|((capabilities&1u)?0x40u:0)|((capabilities&2u)?0x100u:0);
}
uint32_t ps_gem_config(uint32_t old,unsigned speed)
{
    return (old&~0x401u)|2u|(speed==1000?0x400u:speed==100?1u:0u);
}
uint32_t ps_gem_clock(uint32_t old,unsigned speed)
{
    /* KR260 PS preset: integer IOPLL 1 GHz /8 /{1,5,50}. Preserve gates/source.
     * GEM1 uses these divisors. GEM0 remains gigabit-only. The PS-GTR serial
     * reference is separate and remains 125 MHz at all negotiated speeds. */
    return (old&~0x003f3f00u)|(8u<<8)|((speed==1000?1u:speed==100?5u:50u)<<16);
}
