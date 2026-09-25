#include "config.h"
#include "board.h"
#include "FreeRTOS.h"
#include "task.h"
#include "settings_media.h"
#include "xil_printf.h"
static struct config_store store;
static const struct config_io io={settings_media_read,settings_media_truncate,settings_media_write};
static uint8_t effective_mask(const struct switch_config *c)
{
    uint8_t mask=c->admin;
    for (unsigned i=2;i<4;i++) if (!(c->advertise[i]&4u)) mask&=(uint8_t)~(1u<<i);
    if (c->sfp_speed && c->sfp_speed!=1000) mask&=(uint8_t)~0x10u;
    return mask;
}
void settings_init(void)
{
    if (settings_media_present()) config_load(&store,&io);
    else {
        config_defaults(&store.value);store.slot=-1;
        store.saved=false;store.writable=false;store.sequence=0;
    }
#if CONFIG_RECOVERY
    /* Deliberate JTAG recovery build: ignore saved settings without erasing
     * them. An explicit save writes defaults as the next valid generation. */
    config_defaults(&store.value);store.saved=false;
    xil_printf("Settings: recovery build, saved values bypassed\r\n");
#endif
    xil_printf("Settings: %s; SD storage %s\r\n",store.saved?"loaded":"factory defaults",
               store.writable?"available":settings_media_status());
    (void)board_ports_configure(effective_mask(&store.value),store.value.advertise);
}
void settings_get(struct switch_config *out,bool *saved,bool *writable)
{
    /* Only the HTTP caller asks for writable status. Network/STP callers
     * take the RAM snapshot without touching the single-owner USB stack. */
    bool available=false;
    if (writable && settings_media_present()) {
        struct config_store media;config_load(&media,&io);
        available=media.writable;
    }
    taskENTER_CRITICAL();
    *out=store.value;if (saved) *saved=store.saved;if (writable) *writable=available;
    taskEXIT_CRITICAL();
}
bool settings_save(const struct switch_config *value)
{
    /* Recheck the removable medium on every save, including no-op saves.
     * Probe its generations again so a replaced card is never overwritten
     * using generation/ownership information from the previous card. */
    if (!settings_media_present()) return false;
    struct config_store next;
    config_load(&next,&io);
    if (!config_save(&next,&io,value)) return false;
    taskENTER_CRITICAL();store=next;taskEXIT_CRITICAL();
    return board_ports_configure(effective_mask(value),value->advertise);
}
