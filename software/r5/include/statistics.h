#ifndef SWITCH_STATISTICS_H
#define SWITCH_STATISTICS_H
#include <stdint.h>
#include <stdbool.h>
#ifndef STATS_DDR
#define STATS_DDR 0
#endif
#ifndef STATS_DEBUG
#define STATS_DEBUG 0
#endif
struct statistics_snapshot {
    /* Per port: RX good packets, bad packets, good bytes, bad bytes;
     * TX good packets, bad packets, good bytes, bad bytes. CPU RX = into fabric. */
    uint64_t port[6][8];
#if STATS_DDR
    uint64_t ddr[4][8]; /* index 3 is a maximum, all others are sums */
#endif
#if STATS_DEBUG
    uint64_t debug[16];
#endif
    uint64_t timestamp;
    uint32_t polls, late_polls, saturated_reads, read_timeouts, capabilities;
    /* Total above remains the sum of these two timeout classes (mod 2^32). */
    uint32_t mailbox_release_timeouts, snapshot_response_timeouts;
    /* Indexed by hardware bank and slot, including zero-valued unused slots. */
    uint32_t release_timeout_by_index[13][16];
    uint32_t response_timeout_by_index[13][16];
    /* Raw bank<<4 | slot; UINT32_MAX means no event since restart. */
    uint32_t last_release_index, last_release_target_index, last_response_index;
    bool available;
};
struct sensor_snapshot {
    int32_t temperature_mc[2]; /* PS, PL */
    uint32_t voltage_uv[2][3]; /* PS LP/FP/AUX; PL INT/AUX/BRAM */
    int32_t som_current_ua;
    uint32_t som_voltage_uv, som_power_uw;
    uint64_t timestamp;
    uint32_t valid_mask, errors; /* bit0 PS, bit1 PL, bit2 INA260 */
};
void statistics_task(void *unused);
void sensors_task(void *unused);
void statistics_get(struct statistics_snapshot *out);
void sensors_get(struct sensor_snapshot *out);
#endif
