#ifndef SWITCH_AUTH_H
#define SWITCH_AUTH_H
#include "config.h"
#define AUTH_HEADER_SIZE 256
/* Strict HTTP Basic credential verification; no persistent session/cache.
 * Header includes the Basic scheme. UTF-8 passwords up to 128 bytes. */
bool auth_verify(const struct switch_config *cfg,const char *header);
/* Exposed for independent known-answer tests. */
void auth_derive(const uint8_t *password,size_t size,const uint8_t salt[16],uint32_t rounds,uint8_t hash[32]);
#endif
