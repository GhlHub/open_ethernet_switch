#ifndef SWITCH_STP_H
#define SWITCH_STP_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#define STP_NUM_PORTS 5
#define STP_ROOT_NONE 0xffu
#define STP_CLASSIC 0u
#define STP_RAPID 2u
enum stp_state { STP_STATE_DISABLED=0, STP_STATE_BLOCKING, STP_STATE_LISTENING, STP_STATE_LEARNING, STP_STATE_FORWARDING };
enum stp_role { STP_ROLE_DISABLED=0, STP_ROLE_ROOT, STP_ROLE_DESIGNATED, STP_ROLE_BLOCKING, STP_ROLE_BACKUP };
typedef struct { uint16_t priority; uint8_t mac[6]; } stp_bridge_id_t;
struct stp_port_status {
    uint8_t state,role;
    bool link_up;
    uint32_t path_cost,bpdu_rx,bpdu_tx,role_changes;
};
struct stp_status {
    bool enabled;
    uint8_t version;
    bool fault;
    stp_bridge_id_t bridge_id,root_id;
    uint32_t root_path_cost;
    uint8_t root_port;
    bool is_root;
    uint32_t topology_change_count,tcn_rx,rx_dropped,tx_failed;
    struct stp_port_status port[STP_NUM_PORTS];
};
/* All engine calls belong to one owner. Callbacks finish hardware state changes
 * before returning; transmit failures are counted. RX frames include Ethernet
 * and LLC headers, but no FCS. Engine contains no RTOS or hardware dependency. */
struct stp_ops {
    void (*state)(void *context,unsigned port,bool learning,bool forwarding);
    void (*flush)(void *context,unsigned port,bool rapid_ageing);
    bool (*transmit)(void *context,unsigned port,const uint8_t *frame,size_t length);
};
struct stp_bridge;
struct stp_bridge *stp_create(const uint8_t mac[6],uint8_t version,const struct stp_ops *ops,void *context);
void stp_destroy(struct stp_bridge *b);
void stp_port_link_change(struct stp_bridge *b,unsigned port,bool up,uint16_t speed,uint32_t now);
void stp_tick(struct stp_bridge *b,uint32_t now);
bool stp_rx_bpdu(struct stp_bridge *b,unsigned port,const uint8_t *frame,size_t length,uint32_t now);
void stp_get_status(const struct stp_bridge *b,struct stp_status *out);
void stp_task(void *unused);
void stp_status_get(struct stp_status *out);
/* Early startup gate, before physical links are admitted. */
void stp_prepare(bool enabled);
#endif
