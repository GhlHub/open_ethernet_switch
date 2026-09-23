/* IEEE 802.1D-1998 classic STP core: BPDU codec, the fixed-configuration
 * root/designated/blocking election, and the Blocking/Listening/Learning/
 * Forwarding progression timers. No board.h/FreeRTOS dependency -- see
 * stp.h's header for what's deliberately out of scope (TCN propagation).
 *
 * Frame layout this module reads/writes, after the 14-byte Ethernet header
 * (dest 01:80:C2:00:00:00, src = our bridge MAC, 802.3 length field):
 *   offset 14: LLC   DSAP=0x42 SSAP=0x42 Control=0x03           (3 bytes)
 *   offset 17: Protocol ID (2, =0) | Version (1, =0) | Type (1) ...
 *   Config (type 0x00, 35-byte payload, ends at offset 51):
 *     Flags(1) RootID(8) RootPathCost(4) BridgeID(8) PortID(2)
 *     MessageAge(2) MaxAge(2) HelloTime(2) ForwardDelay(2)
 *   TCN (type 0x80, 4-byte payload, ends at offset 20): no further fields.
 * Each 8-byte *ID field is {priority:16 big-endian, mac:48}. The four time
 * fields are 802.1D's native 1/256-second units, not milliseconds. */
#include "stp.h"
#include <string.h>

struct port_state {
    bool     up;
    uint32_t path_cost;
    uint8_t  role, state;
    uint32_t state_timer_ms;
    bool     heard;
    stp_bridge_id_t d_root, d_bridge;
    uint32_t d_cost;
    uint16_t d_port_id;
    uint16_t d_hello_ms, d_max_age_ms, d_fwd_delay_ms;
    uint32_t message_age_ms;
    uint32_t bpdu_rx, bpdu_tx, role_changes;
};

struct stp_bridge {
    stp_bridge_id_t bridge_id;
    uint16_t hello_ms, max_age_ms, fwd_delay_ms; /* own defaults, used when root */
    stp_bridge_id_t root_id;
    uint32_t root_path_cost;
    uint8_t  root_port;
    uint16_t use_hello_ms, use_max_age_ms, use_fwd_delay_ms; /* in effect */
    uint32_t hello_timer_ms;
    uint32_t last_tick_ms;
    bool     have_last_tick;
    uint32_t topology_change_count;
    uint32_t tcn_rx;
    uint32_t uptime_ms;
    struct port_state port[STP_NUM_PORTS];
    uint8_t  tx_buf[STP_NUM_PORTS][60];
};

struct stp_bridge g_stp;

static uint16_t port_id_of(unsigned p) { return (uint16_t)((128u << 8) | (p + 1u)); }
static uint16_t ms_to_units(uint32_t ms) { return (uint16_t)((ms << 8) / 1000u); }
static uint32_t units_to_ms(uint16_t u)  { return ((uint32_t)u * 1000u) >> 8; }

static int bridge_id_cmp(const stp_bridge_id_t *a, const stp_bridge_id_t *b)
{
    if (a->priority != b->priority) return a->priority < b->priority ? -1 : 1;
    for (int i = 0; i < 6; i++) if (a->mac[i] != b->mac[i]) return a->mac[i] < b->mac[i] ? -1 : 1;
    return 0;
}

struct candidate { stp_bridge_id_t root; uint32_t cost; stp_bridge_id_t bridge; uint16_t port_id; };

static int candidate_cmp(const struct candidate *a, const struct candidate *b)
{
    int c = bridge_id_cmp(&a->root, &b->root); if (c) return c;
    if (a->cost != b->cost) return a->cost < b->cost ? -1 : 1;
    c = bridge_id_cmp(&a->bridge, &b->bridge); if (c) return c;
    if (a->port_id != b->port_id) return a->port_id < b->port_id ? -1 : 1;
    return 0;
}

void stp_init(struct stp_bridge *b, const uint8_t mac[6], uint16_t priority)
{
    memset(b, 0, sizeof *b);
    b->bridge_id.priority = priority;
    memcpy(b->bridge_id.mac, mac, 6);
    b->hello_ms = 2000; b->max_age_ms = 20000; b->fwd_delay_ms = 15000;
    b->use_hello_ms = b->hello_ms; b->use_max_age_ms = b->max_age_ms; b->use_fwd_delay_ms = b->fwd_delay_ms;
    b->root_id = b->bridge_id;
    b->root_port = STP_ROOT_NONE;
}

static void put_id(uint8_t *p, const stp_bridge_id_t *id)
{
    p[0] = (uint8_t)(id->priority >> 8); p[1] = (uint8_t)id->priority;
    memcpy(p + 2, id->mac, 6);
}
static void get_id(const uint8_t *p, stp_bridge_id_t *id)
{
    id->priority = (uint16_t)((p[0] << 8) | p[1]);
    memcpy(id->mac, p + 2, 6);
}

/* Fills b->tx_buf[port] and appends one action; returns the frame length. */
static uint16_t build_config(struct stp_bridge *b, unsigned port, uint32_t message_age_ms)
{
    uint8_t *f = b->tx_buf[port];
    memset(f, 0, 52);
    f[0] = 0x01; f[1] = 0x80; f[2] = 0xc2; f[3] = 0x00; f[4] = 0x00; f[5] = 0x00; /* dest */
    memcpy(f + 6, b->bridge_id.mac, 6);                                          /* src */
    f[12] = 0x00; f[13] = 0x26;                                                  /* 802.3 length: 38 */
    f[14] = 0x42; f[15] = 0x42; f[16] = 0x03;                                    /* LLC */
    f[17] = 0x00; f[18] = 0x00;                                                  /* protocol id */
    f[19] = 0x00;                                                                /* version */
    f[20] = 0x00;                                                                /* type: config */
    f[21] = 0x00;                                                                /* flags: none set (no TC) */
    put_id(f + 22, &b->root_id);
    f[30] = (uint8_t)(b->root_path_cost >> 24); f[31] = (uint8_t)(b->root_path_cost >> 16);
    f[32] = (uint8_t)(b->root_path_cost >> 8);  f[33] = (uint8_t)b->root_path_cost;
    put_id(f + 34, &b->bridge_id);
    uint16_t pid = port_id_of(port);
    f[42] = (uint8_t)(pid >> 8); f[43] = (uint8_t)pid;
    uint16_t age = ms_to_units(message_age_ms);
    f[44] = (uint8_t)(age >> 8); f[45] = (uint8_t)age;
    uint16_t ma = ms_to_units(b->use_max_age_ms);
    f[46] = (uint8_t)(ma >> 8); f[47] = (uint8_t)ma;
    uint16_t ht = ms_to_units(b->use_hello_ms);
    f[48] = (uint8_t)(ht >> 8); f[49] = (uint8_t)ht;
    uint16_t fd = ms_to_units(b->use_fwd_delay_ms);
    f[50] = (uint8_t)(fd >> 8); f[51] = (uint8_t)fd;
    return 52; /* fabric_dma_send pads to the 60-byte minimum itself */
}

static void fill_masks(const struct stp_bridge *b, struct stp_actions *out)
{
    out->fwd_mask = 0; out->learn_mask = 0;
    for (unsigned p = 0; p < STP_NUM_PORTS; p++) {
        if (b->port[p].state == STP_STATE_FORWARDING) out->fwd_mask |= (uint8_t)(1u << p);
        if (b->port[p].state == STP_STATE_FORWARDING || b->port[p].state == STP_STATE_LEARNING)
            out->learn_mask |= (uint8_t)(1u << p);
    }
}

static void recompute(struct stp_bridge *b, uint32_t dt_ms, struct stp_actions *out)
{
    struct candidate best;
    best.root = b->bridge_id; best.cost = 0; best.bridge = b->bridge_id; best.port_id = 0;
    int best_port = -1;
    for (unsigned p = 0; p < STP_NUM_PORTS; p++) {
        struct port_state *ps = &b->port[p];
        if (!ps->up || !ps->heard) continue;
        struct candidate c = { ps->d_root, ps->d_cost + ps->path_cost, ps->d_bridge, ps->d_port_id };
        if (candidate_cmp(&c, &best) < 0) { best = c; best_port = (int)p; }
    }
    b->root_id = best.root;
    b->root_path_cost = best.cost;
    b->root_port = (best_port < 0) ? STP_ROOT_NONE : (uint8_t)best_port;
    if (b->root_port == STP_ROOT_NONE) {
        b->use_hello_ms = b->hello_ms; b->use_max_age_ms = b->max_age_ms; b->use_fwd_delay_ms = b->fwd_delay_ms;
    } else {
        struct port_state *rp = &b->port[b->root_port];
        b->use_hello_ms = rp->d_hello_ms; b->use_max_age_ms = rp->d_max_age_ms; b->use_fwd_delay_ms = rp->d_fwd_delay_ms;
    }

    for (unsigned p = 0; p < STP_NUM_PORTS; p++) {
        struct port_state *ps = &b->port[p];
        uint8_t new_role;
        if (!ps->up) {
            new_role = STP_ROLE_DISABLED;
        } else if ((int)p == best_port) {
            new_role = STP_ROLE_ROOT;
        } else {
            struct candidate ours = { b->root_id, b->root_path_cost, b->bridge_id, port_id_of(p) };
            struct candidate heard = { ps->d_root, ps->d_cost, ps->d_bridge, ps->d_port_id };
            new_role = (!ps->heard || candidate_cmp(&ours, &heard) <= 0) ? STP_ROLE_DESIGNATED : STP_ROLE_BLOCKING;
        }

        if (new_role != ps->role) {
            ps->role_changes++;
            if (new_role == STP_ROLE_ROOT || new_role == STP_ROLE_DESIGNATED) {
                if (ps->state == STP_STATE_DISABLED || ps->state == STP_STATE_BLOCKING) {
                    ps->state = STP_STATE_LISTENING; ps->state_timer_ms = 0;
                }
            } else {
                ps->state = (new_role == STP_ROLE_DISABLED) ? STP_STATE_DISABLED : STP_STATE_BLOCKING;
                ps->state_timer_ms = 0;
            }
            ps->role = new_role;
        }

        if (ps->role == STP_ROLE_ROOT || ps->role == STP_ROLE_DESIGNATED) {
            ps->state_timer_ms += dt_ms;
            if (ps->state == STP_STATE_LISTENING && ps->state_timer_ms >= b->use_fwd_delay_ms) {
                ps->state = STP_STATE_LEARNING; ps->state_timer_ms = 0;
            } else if (ps->state == STP_STATE_LEARNING && ps->state_timer_ms >= b->use_fwd_delay_ms) {
                ps->state = STP_STATE_FORWARDING; ps->state_timer_ms = 0;
                b->topology_change_count++;
            }
        }
    }

    if (out) fill_masks(b, out);
}

void stp_port_link_change(struct stp_bridge *b, unsigned port, bool up, uint32_t path_cost,
                           struct stp_actions *out)
{
    out->count = 0;
    if (port >= STP_NUM_PORTS) { fill_masks(b, out); return; }
    struct port_state *ps = &b->port[port];
    ps->up = up;
    if (up) {
        ps->path_cost = path_cost;
        ps->heard = false;
        ps->message_age_ms = 0;
    }
    recompute(b, 0, out);
}

void stp_tick(struct stp_bridge *b, uint32_t now_ms, struct stp_actions *out)
{
    uint32_t dt = b->have_last_tick ? (now_ms - b->last_tick_ms) : 0;
    b->last_tick_ms = now_ms; b->have_last_tick = true;
    b->uptime_ms += dt;

    for (unsigned p = 0; p < STP_NUM_PORTS; p++) {
        struct port_state *ps = &b->port[p];
        if (!ps->heard) continue;
        ps->message_age_ms += dt;
        if (ps->message_age_ms >= b->use_max_age_ms) ps->heard = false;
    }

    recompute(b, dt, out);

    out->count = 0;
    b->hello_timer_ms += dt;
    if (b->hello_timer_ms >= b->use_hello_ms) {
        b->hello_timer_ms = 0;
        for (unsigned p = 0; p < STP_NUM_PORTS && out->count < STP_MAX_ACTIONS; p++) {
            if (b->port[p].role != STP_ROLE_DESIGNATED) continue;
            uint32_t age = (b->root_port == STP_ROOT_NONE) ? 0 : b->port[b->root_port].message_age_ms;
            uint16_t len = build_config(b, p, age);
            out->tx[out->count].port = p; out->tx[out->count].frame = b->tx_buf[p]; out->tx[out->count].len = len;
            out->count++;
            b->port[p].bpdu_tx++;
        }
    }
}

void stp_rx_bpdu(struct stp_bridge *b, unsigned port, const uint8_t *frame, size_t len,
                  uint32_t now_ms, struct stp_actions *out)
{
    out->count = 0;
    fill_masks(b, out); /* every path below returns the CURRENT masks; only a
                          * successfully parsed Config BPDU can change them */
    if (port >= STP_NUM_PORTS || !b->port[port].up) return;
    if (len < 21 || frame[17] != 0x00 || frame[18] != 0x00 || frame[19] != 0x00) return; /* not classic STP */
    struct port_state *ps = &b->port[port];
    if (frame[20] == 0x80) { /* TCN: counted only, see header */
        b->tcn_rx++;
        return;
    }
    if (frame[20] != 0x00 || len < 52) return;
    ps->bpdu_rx++;
    get_id(frame + 22, &ps->d_root);
    ps->d_cost = ((uint32_t)frame[30] << 24) | ((uint32_t)frame[31] << 16) | ((uint32_t)frame[32] << 8) | frame[33];
    get_id(frame + 34, &ps->d_bridge);
    ps->d_port_id = (uint16_t)((frame[42] << 8) | frame[43]);
    ps->message_age_ms = units_to_ms((uint16_t)((frame[44] << 8) | frame[45]));
    ps->d_max_age_ms   = (uint16_t)units_to_ms((uint16_t)((frame[46] << 8) | frame[47]));
    ps->d_hello_ms     = (uint16_t)units_to_ms((uint16_t)((frame[48] << 8) | frame[49]));
    ps->d_fwd_delay_ms = (uint16_t)units_to_ms((uint16_t)((frame[50] << 8) | frame[51]));
    ps->heard = true;
    (void)now_ms;

    /* Reassess roles immediately on new information (dt=0: no time passed
     * within this call, so no forward-delay progress accrues here -- only
     * stp_tick() advances state timers). An RX event never itself
     * originates a BPDU; the next hello tick does. */
    recompute(b, 0, out);
}

void stp_get_status(const struct stp_bridge *b, struct stp_status *out)
{
    memset(out, 0, sizeof *out);
    out->bridge_id = b->bridge_id;
    out->root_id = b->root_id;
    out->root_path_cost = b->root_path_cost;
    out->root_port = b->root_port;
    out->is_root = (b->root_port == STP_ROOT_NONE);
    out->topology_change_count = b->topology_change_count;
    out->tcn_rx = b->tcn_rx;
    for (unsigned p = 0; p < STP_NUM_PORTS; p++) {
        out->port[p].state = b->port[p].state;
        out->port[p].role = b->port[p].role;
        out->port[p].link_up = b->port[p].up;
        out->port[p].path_cost = b->port[p].path_cost;
        out->port[p].bpdu_rx = b->port[p].bpdu_rx;
        out->port[p].bpdu_tx = b->port[p].bpdu_tx;
        out->port[p].role_changes = b->port[p].role_changes;
    }
}
