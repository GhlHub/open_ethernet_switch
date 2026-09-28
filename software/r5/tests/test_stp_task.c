#include <assert.h>
#include <setjmp.h>
#include <stdlib.h>
#include <stdio.h>
#include "../src/stp_task.c"
static struct switch_config configured;
static uint32_t ticks;
static uint8_t fwd=31,learn=31;
static unsigned transitions,tx;
static bool supported=true,failed,tag_valid=true;
static jmp_buf finished;
struct fake_queue {unsigned rd,wr,count,size;unsigned char data[32][sizeof(struct bpdu_event)];};
QueueHandle_t xQueueCreate(unsigned count,unsigned size)
{assert(count==32 && size==sizeof(struct bpdu_event));struct fake_queue *q=calloc(1,sizeof(*q));q->size=size;return q;}
int xQueueReset(QueueHandle_t q){q->rd=q->wr=q->count=0;return 1;}
int xQueueSend(QueueHandle_t q,const void *p,unsigned timeout)
{assert(timeout==0);if(q->count==32)return 0;memcpy(q->data[q->wr++%32],p,q->size);q->count++;return 1;}
int xQueueReceive(QueueHandle_t q,void *p,unsigned timeout)
{assert(timeout==0);if(!q->count)return 0;memcpy(p,q->data[q->rd++%32],q->size);q->count--;return 1;}
void settings_get(struct switch_config *c,bool *s,bool *w){(void)s;(void)w;*c=configured;}
void board_ports_snapshot(struct port_snapshot *p)
{memset(p,0,sizeof(*p));p->forwarding=3;p->physical=3;p->speed_mbps[0]=p->speed_mbps[1]=1000;}
bool pstate_stp_supported(void){return supported;}
bool pstate_failed(void){return failed;}
void pstate_latch_fault(void){failed=true;fwd=0;}
void pstate_fwd_clear(uint8_t m){fwd&=~m;transitions++;}
void pstate_learn_clear(uint8_t m){learn&=~m;transitions++;}
void pstate_fwd_set(uint8_t m){if(!failed)fwd|=m;transitions++;}
void pstate_learn_set(uint8_t m){if(!failed)learn|=m;transitions++;}
bool pstate_cpu_tx_raw(uint8_t mask,const uint8_t *p,size_t n)
{assert(running && n>=52 && (mask==1 || mask==2));assert(p[19]==configured.stp_version);tx++;return true;}
void fabric_dma_last_rx_tag(bool *v,uint8_t *p){*v=tag_valid;*p=0;}
TickType_t xTaskGetTickCount(void){return ticks;}
void vTaskDelay(TickType_t n)
{
    assert(n==10);ticks+=n;struct stp_status s;stp_status_get(&s);
    if(ticks==10){assert(!s.enabled && fwd==31 && transitions==0);configured.stp_enabled=true;}
    if(ticks==20){assert(s.enabled && s.version==2 && fwd==0 && learn==0);}
    if(ticks==30){
        uint8_t invalid[60]={1,0x80,0xc2};
        for(unsigned i=0;i<33;i++)fabric_ctrl_frame_rx(invalid,sizeof invalid);
        tag_valid=false;fabric_ctrl_frame_rx(invalid,sizeof invalid);tag_valid=true;
        assert(rx_dropped==2); /* callbacks only queued frames; no engine reentry */
    }
    if(ticks==100){assert(s.rx_dropped==34);configured.stp_version=0;}
    if(ticks==110){assert(s.enabled && s.version==0 && fwd==0);}
    if(ticks==50000){assert(tx && (fwd&3)==3);configured.stp_enabled=false;}
    if(ticks==50010){assert(!s.enabled && fwd==31 && learn==31);configured.stp_version=2;}
    if(ticks==50020){assert(!s.enabled && s.version==2);supported=false;configured.stp_enabled=true;}
    if(ticks==50030){assert(s.enabled && s.fault && !fwd);longjmp(finished,1);}
}
int main(void)
{
    memset(&configured,0,sizeof configured);configured.mac[0][0]=2;configured.mac[0][5]=1;configured.stp_version=2;
    if(!setjmp(finished))stp_task(NULL);
    free(rx_queue);
    puts("PASS: single-owner task, queued BPDU copies/drop reporting, runtime enable/disable/version changes, classic timers, fail-closed hardware ABI guard");
}
