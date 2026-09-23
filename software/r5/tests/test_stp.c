/* Host test for the pure STP engine (stp.c has no board.h dependency, so
 * this compiles and runs with plain cc, like test_policy.c). The strongest
 * proof this protocol actually works is the classic three-switch triangle:
 * three bridges each with two ports, wired A-B, B-C, C-A. Real STP must
 * elect one root and block exactly one port around the loop, or the
 * network would melt down under a real broadcast storm the moment three
 * switches were cabled this way. */
#include "../src/stp.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void deliver(struct stp_bridge *dst, unsigned dst_port, const struct stp_actions *act,
                     unsigned src_port_matching, uint32_t now_ms, struct stp_actions *dst_out)
{
    for (unsigned i = 0; i < act->count; i++) {
        if (act->tx[i].port != src_port_matching) continue;
        stp_rx_bpdu(dst, dst_port, act->tx[i].frame, act->tx[i].len, now_ms, dst_out);
    }
}

static void test_triangle(void)
{
    struct stp_bridge A, B, C;
    struct stp_actions a, b, c, tmp;
    const uint8_t mac_a[6] = {0x02,0,0,0,0,0x01};
    const uint8_t mac_b[6] = {0x02,0,0,0,0,0x02};
    const uint8_t mac_c[6] = {0x02,0,0,0,0,0x03};
    stp_init(&A, mac_a, 32768);
    stp_init(&B, mac_b, 32768);
    stp_init(&C, mac_c, 32768);
    /* A.port0<->B.port0, B.port1<->C.port0, C.port1<->A.port1 */
    stp_port_link_change(&A, 0, true, 4, &tmp);
    stp_port_link_change(&A, 1, true, 4, &tmp);
    stp_port_link_change(&B, 0, true, 4, &tmp);
    stp_port_link_change(&B, 1, true, 4, &tmp);
    stp_port_link_change(&C, 0, true, 4, &tmp);
    stp_port_link_change(&C, 1, true, 4, &tmp);

    uint32_t now = 0;
    for (int round = 0; round < 40; round++) {
        now += 1000;
        stp_tick(&A, now, &a);
        stp_tick(&B, now, &b);
        stp_tick(&C, now, &c);
        deliver(&B, 0, &a, 0, now, &tmp);
        deliver(&C, 1, &a, 1, now, &tmp);
        deliver(&A, 0, &b, 0, now, &tmp);
        deliver(&C, 0, &b, 1, now, &tmp);
        deliver(&B, 1, &c, 0, now, &tmp);
        deliver(&A, 1, &c, 1, now, &tmp);
    }

    struct stp_status sa, sb, sc;
    stp_get_status(&A, &sa); stp_get_status(&B, &sb); stp_get_status(&C, &sc);

    assert(sa.is_root && "A (lowest MAC) must become root");
    assert(!sb.is_root && !sc.is_root);
    assert(memcmp(sb.root_id.mac, mac_a, 6) == 0);
    assert(memcmp(sc.root_id.mac, mac_a, 6) == 0);

    assert(sa.port[0].role == STP_ROLE_DESIGNATED && sa.port[0].state == STP_STATE_FORWARDING);
    assert(sa.port[1].role == STP_ROLE_DESIGNATED && sa.port[1].state == STP_STATE_FORWARDING);
    assert(sb.port[0].role == STP_ROLE_ROOT && sb.port[0].state == STP_STATE_FORWARDING);
    assert(sc.port[1].role == STP_ROLE_ROOT && sc.port[1].state == STP_STATE_FORWARDING);
    /* the B-C segment: equal cost via the root on both sides, so the lower
     * bridge ID (B) wins designated and C's end blocks -- the one blocked
     * port that keeps this triangle loop-free */
    assert(sb.port[1].role == STP_ROLE_DESIGNATED && sb.port[1].state == STP_STATE_FORWARDING);
    assert(sc.port[0].role == STP_ROLE_BLOCKING && sc.port[0].state == STP_STATE_BLOCKING);

    unsigned forwarding = 0, blocking = 0;
    struct stp_status *all[3] = {&sa, &sb, &sc};
    for (int i = 0; i < 3; i++) for (int p = 0; p < 2; p++) {
        if (all[i]->port[p].state == STP_STATE_FORWARDING) forwarding++;
        if (all[i]->port[p].state == STP_STATE_BLOCKING) blocking++;
    }
    assert(forwarding == 5 && blocking == 1 && "exactly one port blocked around the loop");

    assert(sa.port[0].bpdu_tx > 0 && sa.port[1].bpdu_tx > 0 && "root periodically sends Hello BPDUs");
    assert(sb.port[0].bpdu_rx > 0 && "B actually received A's BPDUs, not just computed in a vacuum");

    printf("PASS: three-switch triangle elects A as root and blocks exactly one port (C's link to B), no active loop\n");
}

static void test_bpdu_wire_format(void)
{
    struct stp_bridge A;
    struct stp_actions a, tmp;
    const uint8_t mac[6] = {0x02,0x4b,0x52,0x32,0x36,0x01};
    stp_init(&A, mac, 32768);
    stp_port_link_change(&A, 0, true, 4, &tmp);

    uint32_t now = 0;
    /* first tick's hello_timer already >= use_hello_ms (starts at 0 with
     * use_hello_ms=2000 and dt from an unset last tick is 0) -- tick twice
     * at the 2s hello period to guarantee at least one transmission */
    stp_tick(&A, now, &a);
    now += 2000;
    stp_tick(&A, now, &a);
    assert(a.count >= 1);
    const uint8_t *f = a.tx[0].frame;
    assert(f[0]==0x01 && f[1]==0x80 && f[2]==0xc2 && f[3]==0 && f[4]==0 && f[5]==0);
    assert(memcmp(f+6, mac, 6) == 0);
    assert(f[14]==0x42 && f[15]==0x42 && f[16]==0x03);
    assert(f[17]==0 && f[18]==0 && f[19]==0 && f[20]==0); /* proto id 0, version 0, config */
    assert(memcmp(f+22, f+34, 8) == 0); /* alone, A is its own root: root id == bridge id */
    assert(f[42]==0x80 && f[43]==0x01); /* port id: priority 128, port number 1 (port 0 = STP port 1) */
    printf("PASS: transmitted Config BPDU has the correct dest MAC/LLC/protocol framing and root==self when alone\n");
}

static void test_aging_reclaims_designated(void)
{
    struct stp_bridge A, B;
    struct stp_actions a, b, tmp;
    const uint8_t mac_a[6] = {0x02,0,0,0,0,0x01}, mac_b[6] = {0x02,0,0,0,0,0x02};
    stp_init(&A, mac_a, 32768); stp_init(&B, mac_b, 4096); /* B has better (lower) priority: B is root */
    stp_port_link_change(&A, 0, true, 4, &tmp);
    stp_port_link_change(&B, 0, true, 4, &tmp);

    uint32_t now = 0;
    for (int i = 0; i < 5; i++) { now += 1000; stp_tick(&A, now, &a); stp_tick(&B, now, &b); deliver(&A, 0, &b, 0, now, &tmp); }
    struct stp_status s; stp_get_status(&A, &s);
    assert(!s.is_root && s.port[0].role == STP_ROLE_ROOT);

    /* B stops sending (simulated link partner disappears without a clean
     * down event, e.g. cable pulled) -- A must age its info out after
     * max_age (20s) and reclaim the port as its own designated */
    for (int i = 0; i < 22; i++) { now += 1000; stp_tick(&A, now, &a); }
    stp_get_status(&A, &s);
    assert(s.is_root && "A reclaims root once B's info ages out");
    assert(s.port[0].role == STP_ROLE_DESIGNATED);
    printf("PASS: a port whose neighbor stops advertising ages out after Max Age and is reclaimed\n");
}

static void test_malformed_frames_ignored(void)
{
    struct stp_bridge A;
    struct stp_actions a, tmp;
    const uint8_t mac[6] = {0x02,0,0,0,0,0x09};
    stp_init(&A, mac, 32768);
    stp_port_link_change(&A, 0, true, 4, &tmp);

    uint8_t garbage[60]; memset(garbage, 0xAA, sizeof garbage);
    stp_rx_bpdu(&A, 0, garbage, sizeof garbage, 1000, &a); /* wrong protocol id/version */
    uint8_t truncated[10] = {0};
    stp_rx_bpdu(&A, 0, truncated, sizeof truncated, 1000, &a); /* too short even for the header check */
    stp_rx_bpdu(&A, 99, garbage, sizeof garbage, 1000, &a);    /* out-of-range port */

    struct stp_status s; stp_get_status(&A, &s);
    assert(s.port[0].bpdu_rx == 0 && "malformed/short frames are ignored, not miscounted as real BPDUs");
    printf("PASS: malformed and out-of-range-port BPDU calls are safely ignored\n");
}

int main(void)
{
    test_bpdu_wire_format();
    test_aging_reclaims_designated();
    test_malformed_frames_ignored();
    test_triangle();
    return 0;
}
