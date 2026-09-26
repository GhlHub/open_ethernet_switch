#ifndef MAC_TABLE_WEB_H
#define MAC_TABLE_WEB_H
#include <stddef.h>
#include <stdbool.h>
/* Caller serializes all calls; GET only polls/copies existing work, never starts.
 * Returns HTTP status, writes bounded JSON or plain error and its length. */
int web_mac_table(char *out, size_t capacity, const char *path, bool refresh, size_t *length);
#endif
