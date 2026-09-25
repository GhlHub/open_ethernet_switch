#ifndef CONFIG_WEB_H
#define CONFIG_WEB_H
#include "config.h"
/* Full port/IP update, optionally with username/salt/hash as one group.
 * Password verifier is PBKDF2-HMAC-SHA256, 100000 rounds, 16-byte salt. */
bool config_form(char *body,struct switch_config *out,bool *credentials);
size_t config_json(char *out,size_t size,const struct switch_config *c,bool saved,bool writable);
#endif
