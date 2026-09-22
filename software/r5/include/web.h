#ifndef SWITCH_WEB_H
#define SWITCH_WEB_H
#include <stddef.h>
#include <stdint.h>
#include "statistics.h"
/* Returns 0 for incomplete, -1 for invalid, 1 for a complete bounded request. */
struct web_request { char method[8], path[64]; unsigned mask; };
int web_parse(const char *data, size_t length, struct web_request *out);
size_t web_stats(char *out, size_t size, const struct statistics_snapshot *s,
                 const struct sensor_snapshot *v, uint32_t hz, uint64_t now);
void web_task(void *unused);
#endif
