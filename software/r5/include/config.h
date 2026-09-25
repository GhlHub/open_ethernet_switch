#ifndef SWITCH_CONFIG_H
#define SWITCH_CONFIG_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define CONFIG_MAC_COUNT 5
#define CONFIG_RECORD_SIZE 256
#define CONFIG_SLOT_SIZE CONFIG_RECORD_SIZE
#define CONFIG_PASSWORD_ROUNDS 100000u
/* Stored preferences, independent of this bitstream's current capabilities.
 * Copper advertisement bits: 10FD=1, 100FD=2, 1000FD=4. GEM0 must be 4.
 * SFP: 0=auto, otherwise speed in Mb/s. */
struct switch_config {
    uint8_t mac[CONFIG_MAC_COUNT][6];
    char username[32];
    uint8_t password_salt[16], password_hash[32];
    uint32_t password_rounds;
    uint8_t admin, advertise[4];
    uint16_t sfp_speed;
    bool dhcp;
    uint8_t ip[4], netmask[4], gateway[4];
};
struct config_io {
    bool (*read)(unsigned slot, unsigned offset, void *data, size_t size);
    bool (*truncate)(unsigned slot);
    bool (*write)(unsigned slot, unsigned offset, const void *data, size_t size);
};
struct config_store {
    struct switch_config value;
    uint32_t sequence;
    int slot;
    bool writable, saved;
};
void config_defaults(struct switch_config *c);
bool config_valid(const struct switch_config *c);
bool config_parse_ipv4(const char *s, uint8_t out[4]);
void config_encode(const struct switch_config *c, uint32_t sequence, uint8_t out[CONFIG_RECORD_SIZE]);
bool config_decode(const uint8_t data[CONFIG_RECORD_SIZE], struct switch_config *c, uint32_t *sequence);
/* Callers serialize load/save. Load never writes; defaults require explicit save. */
bool config_load(struct config_store *s, const struct config_io *io);
bool config_save(struct config_store *s, const struct config_io *io, const struct switch_config *value);
/* Runtime owner: startup, then the single HTTP task. */
void settings_init(void);
void settings_get(struct switch_config *out, bool *saved, bool *writable);
bool settings_save(const struct switch_config *value);
#endif
