/* Register/descriptor model, not an AXI simulation. Link -no-pie so the
 * descriptor pointers fit the real 32-bit DMA address fields. */
#include "board.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static _Thread_local bool lock_held;
void *xSemaphoreCreateMutex(void) { return &mutex; }
int xSemaphoreTake(void *h,unsigned long t) { (void)t; assert(!pthread_mutex_lock(h)); lock_held=true; return 1; }
int xSemaphoreGive(void *h) { lock_held=false; assert(!pthread_mutex_unlock(h)); return 1; }
static uint32_t regs[32], ticks;
static uintptr_t first_rx, current_rx, prior_tx;
static unsigned sends;
static _Thread_local uint8_t expected_flags;
static int mode;
static uint8_t payload[1514];
void barrier(void) {}
uint32_t mmio_read(uintptr_t p)
{
    if (p==DIAG_BASE+CPU_TX_ABI) return mode==3 ? 0 : 0x43545801u;
    if (p==DIAG_BASE+CPU_RX_TAG) return 0; /* not under test here: always "no tag" */
    return regs[(p-DMA_BASE)/4];
}
void mmio_write(uintptr_t p,uint32_t v)
{
    unsigned offset=(unsigned)(p-DMA_BASE);
    if (offset==0 && v==4) { memset(regs,0,sizeof regs); return; }
    regs[offset/4]=v;
    if (offset==0x38) first_rx=current_rx=v;
    if (offset==0x10) {
        assert(lock_held);
        uint32_t *d=(void *)(uintptr_t)v;
        assert(v!=prior_tx); prior_tx=v;
        assert((v&63)==0 && (d[6]&0xc000000)==0xc000000 && d[7]==0);
        uint8_t *data=(void *)(uintptr_t)d[2];
        assert(data[0]==expected_flags && data[1]==0xa5);
        assert(!memcmp(data+2,payload, sends ? (d[6]&0xffff)-2 : 14));
        if (!sends) { assert((d[6]&0xffff)==62); for(int i=16;i<62;i++) assert(data[i]==0); }
        sends++;
        if(mode!=1) d[7]=0x80000000u | (mode==2?0x10000000u:0);
    }
}
uint64_t board_timestamp(void) { return ticks++; }
uint32_t board_timestamp_hz(void) { return 1000; }
uint32_t xTaskGetTickCount(void) { return ticks; }
void vTaskDelay(uint32_t n) { ticks+=n; }
static void *sender(void *arg)
{
    expected_flags=arg ? 0x48 : 0;
    for (unsigned i=0;i<100;i++)
        assert(arg ? fabric_dma_send_directed(payload,64,8) : fabric_dma_send(payload,64));
    return NULL;
}
int main(int argc,char **argv)
{
    mode=argc>1?atoi(argv[1]):0;
    for(unsigned i=0;i<sizeof payload;i++) payload[i]=(uint8_t)(i+1);
    if (mode==3) { assert(!fabric_dma_init()); assert(!fabric_dma_send(payload,14)); puts("PASS: incompatible CPU TX ABI rejected"); return 0; }
    assert(fabric_dma_init());
    if(mode) {
        assert(!fabric_dma_send(payload,14)); assert(!fabric_dma_healthy());
        unsigned before=sends; assert(!fabric_dma_send(payload,14)); assert(sends==before);
        puts("PASS: DMA timeout/error retains ownership and fails closed"); return 0;
    }
    for(int i=0;i<5;i++) assert(fabric_dma_send(payload,i?64:14));
    expected_flags=0x44; assert(fabric_dma_send_directed(payload,64,4));
    expected_flags=0x5f; assert(fabric_dma_send_directed(payload,64,0xff));
    expected_flags=0; assert(fabric_dma_send(payload,64));
    assert(fabric_dma_send(payload,sizeof payload));
    assert(!fabric_dma_send_directed(payload,13,4));
    assert(!fabric_dma_send(payload,13)); assert(!fabric_dma_send(payload,1515));
    pthread_t ordinary, directed;
    unsigned before=sends;
    assert(!pthread_create(&ordinary,NULL,sender,NULL));
    assert(!pthread_create(&directed,NULL,sender,(void *)1));
    assert(!pthread_join(ordinary,NULL)); assert(!pthread_join(directed,NULL));
    assert(sends==before+200);
    uint8_t output[64];
    for(int i=0;i<40;i++) {
        uint32_t *d=(void *)current_rx; assert(d[7]==0 && d[6]==1536);
        memcpy((void *)(uintptr_t)d[2],payload,64); d[7]=0x8c000040;
        assert(fabric_dma_receive(output,sizeof output)==64);
        assert(!memcmp(output,payload,64) && d[7]==0);
        current_rx=d[0];
    }
    uint32_t *d=(void *)current_rx; d[7]=0x88000040; /* missing EOF */
    assert(!fabric_dma_receive(output,sizeof output)); assert(d[7]==0);
    assert(first_rx!=0);
    puts("PASS: DMA padding, TX descriptor rotation, RX ring wrap and malformed RX");
}
