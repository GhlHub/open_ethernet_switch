/* Register/descriptor model, not an AXI simulation. Link -no-pie so the
 * descriptor pointers fit the real 32-bit DMA address fields. */
#include "board.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
static uint32_t regs[32], ticks;
static uintptr_t first_rx, current_rx, prior_tx;
static unsigned sends;
static int mode;
static uint8_t payload[64];
void barrier(void) {}
uint32_t mmio_read(uintptr_t p)
{
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
        uint32_t *d=(void *)(uintptr_t)v;
        assert(v!=prior_tx); prior_tx=v;
        assert((v&63)==0 && (d[6]&0xc000000)==0xc000000 && d[7]==0);
        uint8_t *data=(void *)(uintptr_t)d[2];
        assert(!memcmp(data,payload,14));
        if (!sends) { assert((d[6]&0xffff)==60); for(int i=14;i<60;i++) assert(data[i]==0); }
        sends++;
        if(mode!=1) d[7]=0x80000000u | (mode==2?0x10000000u:0);
    }
}
uint64_t board_timestamp(void) { return ticks++; }
uint32_t board_timestamp_hz(void) { return 1000; }
uint32_t xTaskGetTickCount(void) { return ticks; }
void vTaskDelay(uint32_t n) { ticks+=n; }
int main(int argc,char **argv)
{
    mode=argc>1?atoi(argv[1]):0;
    for(unsigned i=0;i<sizeof payload;i++) payload[i]=(uint8_t)(i+1);
    assert(fabric_dma_init());
    if(mode) {
        assert(!fabric_dma_send(payload,14)); assert(!fabric_dma_healthy());
        unsigned before=sends; assert(!fabric_dma_send(payload,14)); assert(sends==before);
        puts("PASS: DMA timeout/error retains ownership and fails closed"); return 0;
    }
    for(int i=0;i<5;i++) assert(fabric_dma_send(payload,i?64:14));
    assert(!fabric_dma_send(payload,13)); assert(!fabric_dma_send(payload,1515));
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
