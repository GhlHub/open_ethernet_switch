#include "board.h"
#include "pstate.h"
#include "FreeRTOS.h"
#include "task.h"
#include "semphr.h"
static SemaphoreHandle_t control_lock;
static volatile bool control_failed;
static SemaphoreHandle_t lock(void)
{
    taskENTER_CRITICAL();
    if(!control_lock)control_lock=xSemaphoreCreateMutex();
    taskEXIT_CRITICAL();configASSERT(control_lock);return control_lock;
}
/* Every flush-generating write, including link management, shares this lock.
 * Allow CDC propagation before testing busy, and finish before the next toggle. */
static bool wait_flush(void)
{
    for(unsigned i=0;i<100;i++) {
        vTaskDelay(pdMS_TO_TICKS(1));
        if(!(mmio_read(DIAG_BASE+LINK_STATUS)&256u))return true;
    }
    control_failed=true;return false;
}
static void clear_and_flush(unsigned reg,uint8_t mask)
{
    if(!mask)return;
    SemaphoreHandle_t h=lock();xSemaphoreTake(h,portMAX_DELAY);
    if(wait_flush()) {mmio_write(DIAG_BASE+reg,mask&0x3fu);(void)wait_flush();}
    if(control_failed) {
        /* FWD level clears even if a wedged flush cannot complete. No further
         * set is permitted until restart; do not risk reopening a loop. */
        mmio_write(DIAG_BASE+FWD_CLR,0x1f);
    }
    xSemaphoreGive(h);
}
bool pstate_stp_supported(void){return mmio_read(DIAG_BASE+STP_ABI)==0x53545002u;}
void pstate_latch_fault(void){control_failed=true;mmio_write(DIAG_BASE+FWD_CLR,0x1f);}
bool pstate_failed(void){return control_failed;}
void pstate_link_clear(uint8_t mask){clear_and_flush(LINK_CLR,mask);}

void pstate_fwd_set(uint8_t mask)     { if(!control_failed)mmio_write(DIAG_BASE+FWD_SET, mask&0x3fu); }
void pstate_fwd_clear(uint8_t mask)   { clear_and_flush(FWD_CLR,mask); }
void pstate_learn_set(uint8_t mask)   { if(!control_failed)mmio_write(DIAG_BASE+LEARN_SET, mask&0x3fu); }
void pstate_learn_clear(uint8_t mask) { clear_and_flush(LEARN_CLR,mask); }
void pstate_get(uint8_t *fwd, uint8_t *learn)
{
    uint32_t v=mmio_read(DIAG_BASE+PORT_CTRL_STATUS);
    *fwd=(uint8_t)(v&0x3fu); *learn=(uint8_t)((v>>8)&0x3fu);
}
bool pstate_cpu_tx_raw(uint8_t dest_mask, const uint8_t *frame, size_t len)
{
    return fabric_dma_send_directed(frame, len, dest_mask);
}
void __attribute__((weak)) fabric_ctrl_frame_rx(const uint8_t *frame, size_t len)
{ (void)frame; (void)len; }
