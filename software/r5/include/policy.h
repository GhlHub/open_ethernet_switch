#ifndef SWITCH_POLICY_H
#define SWITCH_POLICY_H
#include <stdint.h>
#include <stdbool.h>
/* Millisecond wrap-safe state, independent of FreeRTOS for host tests. */
struct link_policy { uint8_t enabled; uint32_t last_clear_ms; };
struct link_action { uint8_t set, clear; };
struct link_action link_update(struct link_policy *, uint8_t desired, bool busy, uint32_t now);
struct dhcp_policy { bool leased, retry_wait; uint32_t failed_ms; };
void dhcp_result(struct dhcp_policy *, bool leased, uint32_t now);
bool dhcp_retry(struct dhcp_policy *, bool link, uint32_t now);
struct network_link_policy { bool physical, ready; uint32_t up_since_ms; };
bool network_link_ready(struct network_link_policy *, bool up, uint32_t now, uint32_t settle_ms);
#endif
