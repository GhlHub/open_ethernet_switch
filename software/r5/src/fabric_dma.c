/* AXI DMA SG CPU virtual port. One frame per descriptor, copy-based ownership.
 * Descriptors and bounce buffers occupy the non-cacheable DDR MPU region.
 * Driver state and application buffers remain cacheable.
 * Fail closed on DMA error/timeout: never reuse a buffer hardware might own. */
#include "board.h"
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
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
static struct bd rx[RX_COUNT] __attribute__((section(".dma_nocache"), aligned(64)));
/* Two TX descriptors avoid presenting the same tail address consecutively. */
static struct bd tx[2] __attribute__((section(".dma_nocache"), aligned(64)));
static uint8_t rx_data[RX_COUNT][FRAME_BYTES] __attribute__((section(".dma_nocache"), aligned(64)));
static uint8_t tx_data[2][FRAME_BYTES] __attribute__((section(".dma_nocache"), aligned(64)));
static unsigned rx_index, tx_index;
static bool ready, failed;
static bool last_tag_valid; static uint8_t last_tag_port;
/* fabric_dma_send() is now called from two independent tasks: the IP task
 * (network.c's output() callback, ordinary IP-stack traffic) and
 * stp_task.c (BPDU transmission). Both touch the same shared tx[]/tx_data[]/
 * tx_index state with no other synchronization, so a lock is required --
 * see pstate.h's own header on pstate_cpu_tx_raw(). A mutex, not a critical
 * section: fabric_dma_send() blocks (vTaskDelay) waiting for DMA
 * completion, which a critical section must never do. */
static SemaphoreHandle_t tx_lock;
static uint32_t address(const void *p) { return (uint32_t)(uintptr_t)p; }
bool fabric_dma_healthy(void)
{
    if (ready && ((mmio_read(DMA_BASE+4) | mmio_read(DMA_BASE+RX_CH+4)) & DMA_ERRORS)) failed = true;
    return ready && !failed;
}
bool fabric_dma_init(void)
{
    if (ready || failed) return fabric_dma_healthy();
    /* Refuse raw-frame hardware before touching DMA ownership. */
    if (mmio_read(DIAG_BASE+CPU_TX_ABI)!=0x43545801u) { failed=true; return false; }
    if (!tx_lock) tx_lock = xSemaphoreCreateMutex();
    if (!tx_lock) { failed=true; return false; }
    mmio_write(DMA_BASE, 4); /* reset both channels */
    uint64_t start=board_timestamp();
    while (mmio_read(DMA_BASE)&4) {
        if (board_timestamp()-start > board_timestamp_hz()/10u) { failed=true; return false; }
    }
    /* NOLOAD section is outside startup BSS. Initialize only after DMA reset. */
    memset(rx,0,sizeof rx); memset(tx,0,sizeof tx);
    memset(rx_data,0,sizeof rx_data); memset(tx_data,0,sizeof tx_data);
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
static bool send_frame(const uint8_t *p, size_t n, bool directed, uint8_t mask)
{
    if (!p || n<14 || n>1514 || !fabric_dma_healthy()) return false;
    xSemaphoreTake(tx_lock, portMAX_DELAY);
    /* A preceding sender may have failed while this task waited. */
    if (!fabric_dma_healthy()) { xSemaphoreGive(tx_lock); return false; }
    struct bd *d=&tx[tx_index];
    /* Little-endian 16-bit AXIS header: flags/mask byte, then magic. */
    tx_data[tx_index][0]=directed ? (uint8_t)(0x40u|(mask&0x1fu)) : 0;
    tx_data[tx_index][1]=0xa5;
    memcpy(tx_data[tx_index]+2,p,n);
    /* Physical MACs pad, but padding here also keeps all virtual-port frames uniform. */
    size_t bytes=n<60?60:n;
    if (bytes>n) memset(tx_data[tx_index]+2+n,0,bytes-n);
    d->status=0; d->control=SOF_EOF|(uint32_t)(bytes+2);
    barrier(); mmio_write(DMA_BASE+0x10,address(d));
    TickType_t start=xTaskGetTickCount();
    bool ok=true;
    while (!(d->status&COMPLETE)) {
        if (!fabric_dma_healthy() || xTaskGetTickCount()-start>=pdMS_TO_TICKS(100)) {
            failed=true; ok=false; break;
        }
        vTaskDelay(1);
    }
    if (ok) {
        barrier();
        if (d->status&ERRORS) { failed=true; ok=false; }
        else tx_index=(tx_index+1)%2;
    }
    xSemaphoreGive(tx_lock);
    return ok;
}
bool fabric_dma_send(const uint8_t *p, size_t n)
{ return send_frame(p,n,false,0); }
bool fabric_dma_send_directed(const uint8_t *p, size_t n, uint8_t mask)
{ return send_frame(p,n,true,mask); }
size_t fabric_dma_receive(uint8_t *p, size_t capacity)
{
    if (!fabric_dma_healthy()) return 0;
    struct bd *d=&rx[rx_index]; uint32_t status=d->status;
    if (!(status&COMPLETE)) return 0;
    barrier();
    /* Exactly one CPU_RX_TAG read per ring descriptor consumed, whether or
     * not the frame itself turns out well-formed below -- this is the one
     * place that decides a descriptor was consumed, so it must also be the
     * one place that keeps the tag FIFO in lockstep with it (see
     * rx_diag_regs.sv's 0x50 header: reads pop, and network.c's `if (!n)
     * break` on a bad frame would otherwise desync the two streams). */
    uint32_t tag=mmio_read(DIAG_BASE+CPU_RX_TAG);
    last_tag_valid=(tag&0x80000000u)!=0; last_tag_port=(uint8_t)(tag&7u);
    size_t n=status&0xffffu;
    if ((status&(ERRORS|SOF_EOF))!=SOF_EOF || n<14 || n>1514 || n>capacity) n=0;
    if (n) memcpy(p,rx_data[rx_index],n);
    d->status=0; barrier();
    mmio_write(DMA_BASE+RX_CH+0x10,address(d));
    rx_index=(rx_index+1)%RX_COUNT;
    return n;
}
void fabric_dma_last_rx_tag(bool *valid, uint8_t *ingress_port)
{
    *valid=last_tag_valid; *ingress_port=last_tag_port;
}
