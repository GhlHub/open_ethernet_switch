#ifndef IP_DISCOVERY_H
#define IP_DISCOVERY_H
#include <stdint.h>
#include <stddef.h>
#define IP_DISCOVERY_PER_MAC 4
#define IP_DISCOVERY_CAPACITY 128
#define IP_DISCOVERY_TTL_MS 600000u
struct ip_observation { uint8_t ip[4]; uint32_t age_ms; };
/* Passive, untagged Ethernet/IPv4 ARP only; no network transmissions. */
void ip_discovery_observe(const uint8_t *frame, size_t length);
size_t ip_discovery_lookup(const uint8_t mac[6], struct ip_observation out[IP_DISCOVERY_PER_MAC]);
/* Stack cache fallback; age is unavailable. Implemented by network.c. */
int network_cached_ipv4(const uint8_t mac[6], uint8_t ip[4]);
#endif
