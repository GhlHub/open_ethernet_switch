/* Only this task enters the protocol engine. Network RX queues owned BPDU
 * copies; web readers get a published snapshot; settings are polled from RAM. */
#include "board.h"
#include "config.h"
#include "pstate.h"
#include "stp.h"
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include <string.h>
static QueueHandle_t rx_queue;
static struct stp_status published;
static uint32_t rx_dropped;
static volatile bool running;
static bool changing;
static uint8_t desired_fwd,desired_learn;
struct bpdu_event { uint32_t received; uint16_t length; uint8_t port; uint8_t frame[1514]; };
static uint32_t now_ms(void){return (uint32_t)(xTaskGetTickCount()*portTICK_PERIOD_MS);}
void stp_prepare(bool enabled)
{
    if(enabled && !pstate_stp_supported())pstate_latch_fault();
    if(enabled){pstate_fwd_clear(0x1f);pstate_learn_clear(0x1f);}
}
static void state(void *ctx,unsigned p,bool learn,bool forward)
{
    (void)ctx;uint8_t bit=1u<<p;
    if(changing)learn=forward=false;
    /* Block first; wait for queued traffic/MAC flush before reopening. */
    if(!forward && (desired_fwd&bit)){pstate_fwd_clear(bit);desired_fwd&=~bit;}
    if(!learn && (desired_learn&bit)){pstate_learn_clear(bit);desired_learn&=~bit;}
    if(learn && !(desired_learn&bit)){pstate_learn_set(bit);desired_learn|=bit;}
    if(forward && !(desired_fwd&bit)){pstate_fwd_set(bit);desired_fwd|=bit;}
}
static void flush(void *ctx,unsigned p,bool rapid)
{
    (void)ctx;(void)rapid;uint8_t bit=1u<<p;
    /* Hardware couples port FDB flush to queue flush. Briefly stop forwarding,
     * perform the complete flush, then restore the protocol's intended state. */
    pstate_fwd_clear(bit);
    if((desired_fwd&bit) && !changing)pstate_fwd_set(bit);
}
static bool transmit(void *ctx,unsigned p,const uint8_t *f,size_t n)
{(void)ctx;return !changing && !pstate_failed() && pstate_cpu_tx_raw(1u<<p,f,n);}
static const struct stp_ops ops={state,flush,transmit};
void fabric_ctrl_frame_rx(const uint8_t *f,size_t n)
{
    if(n<21 || n>1514 || memcmp(f,"\x01\x80\xc2\0\0\0",6))return;
    bool valid;uint8_t port;fabric_dma_last_rx_tag(&valid,&port);
    if(!running || !rx_queue)return;
    if(!valid || port>=STP_NUM_PORTS){taskENTER_CRITICAL();rx_dropped++;taskEXIT_CRITICAL();return;}
    struct bpdu_event e={.received=now_ms(),.length=n,.port=port};memcpy(e.frame,f,n);
    if(xQueueSend(rx_queue,&e,0)!=pdPASS){taskENTER_CRITICAL();rx_dropped++;taskEXIT_CRITICAL();}
}
void stp_status_get(struct stp_status *out)
{taskENTER_CRITICAL();*out=published;taskEXIT_CRITICAL();}
void stp_task(void *unused)
{
    (void)unused;struct stp_bridge *engine=NULL;
    struct switch_config cfg;uint8_t version=255,links=0;uint16_t speeds[STP_NUM_PORTS]={0};
    rx_queue=xQueueCreate(32,sizeof(struct bpdu_event));configASSERT(rx_queue);
    uint32_t tick=now_ms();bool enabled=false;
    for(;;) {
        settings_get(&cfg,NULL,NULL);
        if(!enabled && !cfg.stp_enabled) {
            version=cfg.stp_version;desired_fwd=desired_learn=0x1f;
        } else if(cfg.stp_enabled!=enabled || cfg.stp_version!=version) {
            taskENTER_CRITICAL();running=false;taskEXIT_CRITICAL();
            changing=true;pstate_fwd_clear(0x1f);pstate_learn_clear(0x1f);
            desired_fwd=desired_learn=0;
            stp_destroy(engine);engine=NULL;xQueueReset(rx_queue);
            links=0;memset(speeds,0,sizeof(speeds));
            enabled=cfg.stp_enabled;version=cfg.stp_version;changing=false;
            if(enabled && !pstate_stp_supported())pstate_latch_fault();
            if(enabled && !pstate_failed()){engine=stp_create(cfg.mac[0],version,&ops,NULL);configASSERT(engine);}
            else if(!enabled) {pstate_learn_set(0x1f);pstate_fwd_set(0x1f);desired_fwd=desired_learn=0x1f;}
            tick=now_ms();taskENTER_CRITICAL();running=enabled;taskEXIT_CRITICAL();
        }
        struct port_snapshot ports;board_ports_snapshot(&ports);
        if(engine) {
            uint8_t next=ports.forwarding&0x1f;
            for(unsigned p=0;p<STP_NUM_PORTS;p++)if(((next^links)&(1u<<p)) || speeds[p]!=ports.speed_mbps[p]) {
                stp_port_link_change(engine,p,(next&(1u<<p))!=0,ports.speed_mbps[p],now_ms());speeds[p]=ports.speed_mbps[p];
            }
            links=next;
            /* Bounded draining guarantees link/configuration/timer service. */
            struct bpdu_event e;
            for(unsigned i=0;i<16 && xQueueReceive(rx_queue,&e,0)==pdPASS;i++) {
                if((uint32_t)(now_ms()-e.received)>1000 || !stp_rx_bpdu(engine,e.port,e.frame,e.length,now_ms())) {taskENTER_CRITICAL();rx_dropped++;taskEXIT_CRITICAL();}
            }
            uint32_t now=now_ms();
            if((uint32_t)(now-tick)>=1000){tick+=1000;stp_tick(engine,now);}

        }
        struct stp_status s={0};
        if(engine)stp_get_status(engine,&s);
        else {memcpy(s.bridge_id.mac,cfg.mac[0],6);s.bridge_id.priority=32768;s.root_id=s.bridge_id;s.root_port=STP_ROOT_NONE;s.is_root=true;}
        s.enabled=enabled;s.version=version;s.fault=pstate_failed();
        taskENTER_CRITICAL();s.rx_dropped=rx_dropped;published=s;taskEXIT_CRITICAL();
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
