#ifndef SWITCH_SNMP_H
#define SWITCH_SNMP_H
#include <stddef.h>
#include <stdint.h>
#include "statistics.h"
/* RFC 5612 example PEN: replace for deployment outside this lab. */
#ifndef SNMP_ENTERPRISE
#define SNMP_ENTERPRISE 32473u
#endif
#ifndef SNMP_COMMUNITY
#define SNMP_COMMUNITY "public"
#endif
#define SNMP_PACKET_MAX 1400
#define SNMP_OID_MAX 24
#define SNMP_OBJECT_MAX 160
struct snmp_oid { uint32_t arc[SNMP_OID_MAX]; size_t length; };
struct snmp_object {
    struct snmp_oid oid;
    uint8_t type;
    uint64_t number;
    const char *text;
};
struct snmp_mib { struct snmp_object object[SNMP_OBJECT_MAX]; size_t count; };
void snmp_mib_build(struct snmp_mib *, const struct statistics_snapshot *,
                    const struct sensor_snapshot *, uint64_t now, uint32_t hz,
                    uint32_t uptime_cs, uint32_t links);
/* Pure, bounded BER engine; returns zero for discarded requests. */
size_t snmp_respond(const uint8_t *, size_t, uint8_t *, size_t,
                    const char *community, const struct snmp_mib *);
void snmp_task(void *unused);
#endif
