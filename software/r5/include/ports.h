#ifndef SWITCH_PORTS_H
#define SWITCH_PORTS_H
#include <stdint.h>
#include <stdbool.h>
/* GEM0 PS-GTR SGMII supports 1000 only (mask 4); GEM1 supports masks 1..7.
 * Advertisement bits: 10FD=1, 100FD=2, 1000FD=4. Zero is invalid. */
#define PS_ADV_ALL 7u
struct port_snapshot {
    uint8_t admin, physical, forwarding;
    uint8_t advertise[2], applied[2];
    uint16_t speed_mbps[6]; /* 0 = no supported resolved link / CPU virtual */
};
void board_ports_snapshot(struct port_snapshot *out);
bool board_ports_configure(uint8_t mask,const uint8_t advertise[2]);
unsigned ps_phy_speed(uint16_t status);
uint16_t ps_phy_advertisement(unsigned capabilities);
uint32_t ps_gem_config(uint32_t old,unsigned speed);
uint32_t ps_gem_clock(uint32_t old,unsigned speed);
#endif
