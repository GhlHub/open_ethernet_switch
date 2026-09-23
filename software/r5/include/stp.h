#ifndef SWITCH_STP_H
#define SWITCH_STP_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
/* IEEE 802.1D-1998 classic Spanning Tree Protocol (not RSTP/MSTP): the
 * fixed-configuration Config/TCN BPDU exchange, port role/state election
 * (Root/Designated/Blocking; Blocking/Listening/Learning/Forwarding) and
 * the four standard timers (Hello 2s, Max Age 20s, Forward Delay 15s).
 * Pure algorithm only -- no board.h/FreeRTOS dependency, so this is
 * host-testable exactly like policy.c. The hardware glue (link status
 * polling, pstate_fwd/learn_*, pstate_cpu_tx_raw, the fabric_ctrl_frame_rx
 * override, and the periodic task loop) lives in stp_task.c.
 *
 * Only the 5 physical ports run STP (buf_mgr_pkg::NUM_PORTS' CPU slot,
 * index 5, is never a spanning-tree port -- it's this bridge itself).
 *
 * Known, deliberate simplification: Topology Change Notification BPDUs are
 * parsed (counted) but not acted on -- this bridge does not propagate a TC
 * flag toward the root or shorten aging time network-wide on a topology
 * change. topology_change_count in stp_get_status() instead counts local
 * port-forwarding transitions, a real and useful (if narrower) signal that
 * the tree is changing, without the flag-propagation machinery. */
#define STP_NUM_PORTS 5
#define STP_ROOT_NONE 0xffu

enum stp_state { STP_STATE_DISABLED = 0, STP_STATE_BLOCKING, STP_STATE_LISTENING, STP_STATE_LEARNING, STP_STATE_FORWARDING };
enum stp_role  { STP_ROLE_DISABLED = 0, STP_ROLE_ROOT, STP_ROLE_DESIGNATED, STP_ROLE_BLOCKING };

typedef struct { uint16_t priority; uint8_t mac[6]; } stp_bridge_id_t;

struct stp_port_status {
    uint8_t  state, role;
    bool     link_up;
    uint32_t path_cost;
    uint32_t bpdu_rx, bpdu_tx, role_changes;
};

struct stp_status {
    bool     enabled;      /* see stp_task.c: defaults false, no control yet */
    stp_bridge_id_t bridge_id;
    stp_bridge_id_t root_id;
    uint32_t root_path_cost;
    uint8_t  root_port;   /* STP_ROOT_NONE if this bridge is the root */
    bool     is_root;
    uint32_t topology_change_count;
    uint32_t tcn_rx;       /* TCN BPDUs seen (counted only, see header) */
    struct stp_port_status port[STP_NUM_PORTS];
};

struct stp_bridge; /* opaque; see stp.c */
extern struct stp_bridge g_stp;

void stp_init(struct stp_bridge *b, const uint8_t mac[6], uint16_t priority);

/* Data-only actions the caller must perform after stp_port_link_change()/
 * stp_tick()/stp_rx_bpdu() return, before calling any of the three again
 * (the tx frame buffers are reused static storage, valid only until the
 * next call). Kept explicit so the algorithm above has no direct hardware
 * dependency. fwd_mask/learn_mask are always filled with the CURRENT
 * desired mask on every call, whether or not anything changed -- safe for
 * the caller to unconditionally re-apply. */
struct stp_action { unsigned port; const uint8_t *frame; uint16_t len; };
#define STP_MAX_ACTIONS STP_NUM_PORTS
struct stp_actions {
    unsigned count;
    struct stp_action tx[STP_MAX_ACTIONS];
    uint8_t fwd_mask, learn_mask;
};

/* path_cost is ignored when up=false. Reassesses roles immediately (a port
 * going down can change who the root port is; going up starts that port in
 * Blocking, same as reset), so fwd_mask/learn_mask may already reflect the
 * new port even before the next stp_tick(). */
void stp_port_link_change(struct stp_bridge *b, unsigned port, bool up, uint32_t path_cost,
                           struct stp_actions *out);
void stp_tick(struct stp_bridge *b, uint32_t now_ms, struct stp_actions *out);
void stp_rx_bpdu(struct stp_bridge *b, unsigned port, const uint8_t *frame, size_t len,
                  uint32_t now_ms, struct stp_actions *out);
void stp_get_status(const struct stp_bridge *b, struct stp_status *out);

/* Hardware glue (stp_task.c): initializes g_stp and runs the periodic
 * tick/link-poll loop. Not part of the pure engine above. */
void stp_task(void *unused);
/* Thread-safe snapshot of g_stp for any other task (web/console) to read;
 * wraps stp_get_status() in a critical section, same pattern as
 * board_ports_snapshot()/statistics_get(). */
void stp_status_get(struct stp_status *out);
/* Runtime enable/disable, defaulting to disabled -- see stp_task.c's
 * header. No caller exists yet; pending web control and persistent
 * configuration will call stp_set_enabled(). Disabling restores hardware
 * to its pre-STP default (all ports forwarding/learning); enabling starts
 * the engine fresh, as if the board had just booted with STP already on. */
bool stp_get_enabled(void);
void stp_set_enabled(bool enabled);
#endif
