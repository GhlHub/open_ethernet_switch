#ifndef SWITCH_PSTATE_H
#define SWITCH_PSTATE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
/* Per-port data-plane control, independent of physical link admission
 * (board.h's LINK_SET/CLR, owned by links.c): a hook for 802.1D STP/RSTP
 * port states, or similar future protocols. stp_task.c drives these when
 * STP is enabled; STP defaults disabled. FWD_EN/LEARN_EN reset enabled. */
void pstate_fwd_set(uint8_t mask);
void pstate_fwd_clear(uint8_t mask);
void pstate_learn_set(uint8_t mask);
void pstate_learn_clear(uint8_t mask);
void pstate_get(uint8_t *fwd, uint8_t *learn);
/* Transmits one raw frame out exactly the ports in dest_mask, bypassing the
 * CPU port's normal learned-unicast-or-flood resolution (see
 * rtl/switch_top.sv's header: the CPU cannot otherwise target one specific
 * egress port). The hook a future STP/LACP/LLDP task uses to send its own
 * per-port frames. Metadata is prepended under the same DMA mutex as the
 * frame; concurrent ordinary and directed callers are supported. Only the
 * five physical destination bits are used; the CPU source port is excluded. */
bool pstate_cpu_tx_raw(uint8_t dest_mask, const uint8_t *frame, size_t len);
/* Reserved link-layer control block (01:80:C2:00:00:0x): STP/RSTP/MSTP
 * BPDUs, LACP/OAM (Slow Protocols), LLDP, and anything else IEEE 802.1
 * reserves that address range for -- see rtl/mac_table/mac_addr_resolver.sv's
 * header. Hardware always routes these to the CPU port alone; network.c
 * calls this for exactly those frames instead of handing them to the IP
 * stack (which would otherwise silently drop them: they are never IP/ARP
 * traffic for the board's own MAC). The default (weak) implementation does
 * nothing; a real protocol implementation overrides it. */
void fabric_ctrl_frame_rx(const uint8_t *frame, size_t len);
#endif
