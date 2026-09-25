/* Hardware glue for the pure STP engine in stp.c: polls per-port link
 * admission and speed, drives FWD_EN/LEARN_EN through pstate.c, transmits
 * BPDUs via the CPU TX override, and receives them through the strong
 * override of pstate.c's weak fabric_ctrl_frame_rx hook.
 *
 * Defaults DISABLED: no web control or persistent configuration exists yet
 * (pending future work), so there is currently no way to turn this on at
 * all short of changing stp_enabled's initializer below and rebuilding.
 * While disabled, this file touches no hardware and passively drops
 * control-block frames (fabric_ctrl_frame_rx() is a no-op, same as the
 * original weak default) -- the switch behaves exactly as it did before
 * this feature existed. */
#include "board.h"
#include "config.h"
#include "pstate.h"
#include "stp.h"
#include "FreeRTOS.h"
#include "task.h"
#include "xil_printf.h"

static uint8_t stp_mac[6]; /* first allocated board MAC, shared with network.c */
static bool stp_enabled = false;
static uint8_t applied_fwd = 0x1f, applied_learn = 0x1f; /* matches hardware's own reset default */
static uint8_t last_forwarding;
static bool have_last_forwarding;

static uint32_t now_ms(void) { return (uint32_t)(xTaskGetTickCount()*portTICK_PERIOD_MS); }

static uint32_t path_cost_for_speed(uint16_t mbps)
{
    /* 802.1D-1998 recommended values; a down port's cost is never used. */
    if (mbps >= 1000) return 4;
    if (mbps >= 100) return 19;
    if (mbps) return 100;
    return 4;
}

static void apply_actions(const struct stp_actions *act)
{
    uint8_t set = (uint8_t)(act->fwd_mask & ~applied_fwd);
    uint8_t clr = (uint8_t)(~act->fwd_mask & applied_fwd & 0x1fu);
    if (set) pstate_fwd_set(set);
    if (clr) pstate_fwd_clear(clr);
    applied_fwd = act->fwd_mask;

    set = (uint8_t)(act->learn_mask & ~applied_learn);
    clr = (uint8_t)(~act->learn_mask & applied_learn & 0x1fu);
    if (set) pstate_learn_set(set);
    if (clr) pstate_learn_clear(clr);
    applied_learn = act->learn_mask;

    for (unsigned i = 0; i < act->count; i++)
        (void)pstate_cpu_tx_raw((uint8_t)(1u << act->tx[i].port), act->tx[i].frame, act->tx[i].len);
}

static void poll_links(void)
{
    struct port_snapshot p; board_ports_snapshot(&p);
    uint8_t forwarding = p.forwarding & PHYSICAL_PORT_MASK;
    uint8_t changed = have_last_forwarding ? (uint8_t)(forwarding ^ last_forwarding) : forwarding;
    have_last_forwarding = true;
    for (unsigned port = 0; port < STP_NUM_PORTS; port++) {
        if (!(changed & (1u << port))) continue;
        bool up = (forwarding & (1u << port)) != 0;
        struct stp_actions act;
        stp_port_link_change(&g_stp, port, up, path_cost_for_speed(p.speed_mbps[port]), &act);
        apply_actions(&act);
        xil_printf("STP: port %u %s\r\n", port, up ? "up" : "down");
    }
    last_forwarding = forwarding;
}

void fabric_ctrl_frame_rx(const uint8_t *frame, size_t len)
{
    if (!stp_enabled) return;
    bool valid; uint8_t port;
    fabric_dma_last_rx_tag(&valid, &port);
    if (!valid || port >= STP_NUM_PORTS) return; /* not a physical port's frame; nothing to attribute it to */
    struct stp_actions act;
    stp_rx_bpdu(&g_stp, port, frame, len, now_ms(), &act);
    apply_actions(&act);
}

void stp_status_get(struct stp_status *out)
{
    taskENTER_CRITICAL();
    stp_get_status(&g_stp, out);
    taskEXIT_CRITICAL();
    out->enabled = stp_enabled;
}

bool stp_get_enabled(void) { return stp_enabled; }

/* No caller exists yet (see header) -- this exists so the pending web
 * control/persistence work has a clean single entry point to call into. */
void stp_set_enabled(bool enabled)
{
    if (enabled == stp_enabled) return;
    stp_enabled = enabled;
    if (!enabled) {
        /* Restore hardware to exactly its pre-STP default (all enabled)
         * rather than leaving whatever mask was last applied. */
        struct stp_actions act = {0};
        act.fwd_mask = 0x1f; act.learn_mask = 0x1f;
        apply_actions(&act);
    } else {
        /* Start clean: re-init the engine and treat every currently-up
         * port as a fresh link-up event, same as at boot. */
        struct switch_config cfg; settings_get(&cfg,NULL,NULL);
        for (unsigned i=0;i<6;i++) stp_mac[i]=cfg.mac[0][i];
        stp_init(&g_stp, stp_mac, 32768);
        have_last_forwarding = false;
    }
}

void stp_task(void *unused)
{
    (void)unused;
    struct switch_config cfg; settings_get(&cfg,NULL,NULL);
    for (unsigned i=0;i<6;i++) stp_mac[i]=cfg.mac[0][i];
    stp_init(&g_stp, stp_mac, 32768);
    xil_printf("STP: bridge %02x:%02x:%02x:%02x:%02x:%02x priority 32768, %u ports (disabled by default)\r\n",
        stp_mac[0],stp_mac[1],stp_mac[2],stp_mac[3],stp_mac[4],stp_mac[5], STP_NUM_PORTS);
    TickType_t wake = xTaskGetTickCount();
    for (;;) {
        if (stp_enabled) {
            poll_links();
            struct stp_actions act;
            stp_tick(&g_stp, now_ms(), &act);
            apply_actions(&act);
        }
        vTaskDelayUntil(&wake, pdMS_TO_TICKS(1000));
    }
}
