/* AXI DMA SG CPU virtual port. One frame per descriptor, copy-based ownership.
 * All storage is in reserved R5 DDR and D-cache is disabled at board startup.
 * Fail closed on DMA error/timeout: never reuse a buffer hardware might own. */
#include "board.h"
#include "FreeRTOS.h"
#include "task.h"
#include <string.h>
#define RX_COUNT 16u
#define FRAME_BYTES 1536u
#define COMPLETE 0x80000000u
#define ERRORS 0x70000000u
#define SOF_EOF 0x0c000000u
#define RX_CH 0x30u
#define DMA_ERRORS 0x770u
struct bd { uint32_t next, next_hi, buffer, buffer_hi, reserved[2], control; volatile uint32_t status; uint32_t app[8]; };
_Static_assert(sizeof(struct bd) == 64, "AXI DMA descriptor alignment");
static struct bd rx[RX_COUNT] __attribute__((aligned(64)));
/* Two TX descriptors avoid presenting the same tail address consecutively. */
static struct bd tx[2] __attribute__((aligned(64)));
static uint8_t rx_data[RX_COUNT][FRAME_BYTES] __attribute__((aligned(64)));
static uint8_t tx_data[2][FRAME_BYTES] __attribute__((aligned(64)));
static unsigned rx_index, tx_index;
static bool ready, failed;
static uint32_t address(const void *p) { return (uint32_t)(uintptr_t)p; }
bool fabric_dma_healthy(void)
{
    if (ready && ((mmio_read(DMA_BASE+4) | mmio_read(DMA_BASE+RX_CH+4)) & DMA_ERRORS)) failed = true;
    return ready && !failed;
}
bool fabric_dma_init(void)
{
    if (ready || failed) return fabric_dma_healthy();
    mmio_write(DMA_BASE, 4); /* reset both channels */
    uint64_t start=board_timestamp();
    while (mmio_read(DMA_BASE)&4) {
        if (board_timestamp()-start > board_timestamp_hz()/10u) { failed=true; return false; }
    }
    for (unsigned i=0;i<RX_COUNT;i++) {
        rx[i].next=address(&rx[(i+1)%RX_COUNT]);
        rx[i].buffer=address(rx_data[i]); rx[i].control=FRAME_BYTES;
    }
    for (unsigned i=0;i<2;i++) {
        tx[i].next=address(&tx[(i+1)%2]); tx[i].buffer=address(tx_data[i]);
    }
    barrier();
    mmio_write(DMA_BASE+RX_CH+8,address(rx));
    mmio_write(DMA_BASE+RX_CH,1); /* interrupts masked; RX task polls */
    mmio_write(DMA_BASE+RX_CH+0x10,address(&rx[RX_COUNT-1]));
    mmio_write(DMA_BASE+8,address(tx));
    mmio_write(DMA_BASE,1);
    ready=true;
    return fabric_dma_healthy();
}
bool fabric_dma_send(const uint8_t *p, size_t n)
{
    if (!fabric_dma_healthy() || n<14 || n>1514) return false;
    struct bd *d=&tx[tx_index];
    memcpy(tx_data[tx_index],p,n);
    /* Physical MACs pad, but padding here also keeps all virtual-port frames uniform. */
    size_t bytes=n<60?60:n;
    if (bytes>n) memset(tx_data[tx_index]+n,0,bytes-n);
    d->status=0; d->control=SOF_EOF|(uint32_t)bytes;
    barrier(); mmio_write(DMA_BASE+0x10,address(d));
    TickType_t start=xTaskGetTickCount();
    while (!(d->status&COMPLETE)) {
        if (!fabric_dma_healthy() || xTaskGetTickCount()-start>=pdMS_TO_TICKS(100)) {
            failed=true; return false;
        }
        vTaskDelay(1);
    }
    barrier();
    if (d->status&ERRORS) { failed=true; return false; }
    tx_index=(tx_index+1)%2;
    return true;
}
size_t fabric_dma_receive(uint8_t *p, size_t capacity)
{
    if (!fabric_dma_healthy()) return 0;
    struct bd *d=&rx[rx_index]; uint32_t status=d->status;
    if (!(status&COMPLETE)) return 0;
    barrier();
    size_t n=status&0xffffu;
    if ((status&(ERRORS|SOF_EOF))!=SOF_EOF || n<14 || n>1514 || n>capacity) n=0;
    if (n) memcpy(p,rx_data[rx_index],n);
    d->status=0; barrier();
    mmio_write(DMA_BASE+RX_CH+0x10,address(d));
    rx_index=(rx_index+1)%RX_COUNT;
    return n;
}
