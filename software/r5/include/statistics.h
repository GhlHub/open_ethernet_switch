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
