#ifndef SWITCH_MAC_DUMP_H
#define SWITCH_MAC_DUMP_H
#include <stdint.h>
#include <stddef.h>

#define MAC_DUMP_BASE 0x80110000UL
#define MAC_DUMP_ENTRIES 2048u
#define MAC_DUMP_BYTES (MAC_DUMP_ENTRIES * 16u)
#define MAC_DUMP_ALIGNMENT 256u
/* Little-endian record. MAC = (mac_high << 32) | mac_low, not wire byte order. */
struct mac_dump_record {
    uint32_t mac_low;
    uint16_t mac_high;
    uint8_t port_mask, reserved;
    uint16_t age_seconds, index;
    uint32_t flags; /* bit 0: valid (age != 0) */
};
enum mac_dump_result {
    MAC_DUMP_IDLE, MAC_DUMP_BUSY, MAC_DUMP_DONE, MAC_DUMP_ERROR,
    MAC_DUMP_UNAVAILABLE, MAC_DUMP_BAD_BUFFER, MAC_DUMP_STARTED
};
/* Single-owner task API: serialize calls and do not also program the CSRs.
 * Pass an exclusively owned, cache-line-isolated, 256-byte-aligned DDR buffer
 * of at least MAC_DUMP_BYTES bytes. Do not read/write/free it until poll returns
 * DONE or ERROR. A timeout leaves ownership with hardware: KEEP POLLING.
 * STARTED transfers ownership; other start results leave the supplied buffer
 * with the caller. A new start is forbidden while busy. No ISR use or independent PL reset. */
enum mac_dump_result mac_dump_start(struct mac_dump_record *buffer, size_t bytes);
/* completed_bytes counts successful full bursts; error_code: 1 AXI, 2 address.
 * DONE/ERROR returns buffer ownership with cache invalidation complete.
 * Errors may have written additional data beyond completed_bytes. */
enum mac_dump_result mac_dump_poll(uint32_t *completed_bytes, uint32_t *error_code);
#endif
