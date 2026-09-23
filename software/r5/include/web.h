#ifndef SWITCH_WEB_H
#define SWITCH_WEB_H
#include <stddef.h>
#include <stdint.h>
#include "statistics.h"
#include "ports.h"
#include "stp.h"
/* Returns 0 for incomplete, -1 for invalid, 1 for a complete bounded request. */
struct web_request { char method[8], path[64]; unsigned mask; uint8_t advertise[2]; };
int web_parse(const char *data, size_t length, struct web_request *out);
size_t web_stats(char *out, size_t size, const struct statistics_snapshot *s,
                 const struct sensor_snapshot *v, uint32_t hz, uint64_t now, const struct port_snapshot *ports,
                 const struct stp_status *stp);
size_t web_ports(char *out,size_t size,const struct port_snapshot *ports);
void web_task(void *unused);
#endif
