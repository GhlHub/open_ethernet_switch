#include "board.h"
#include "pstate.h"
void pstate_fwd_set(uint8_t mask)     { mmio_write(DIAG_BASE+FWD_SET, mask&0x3fu); }
void pstate_fwd_clear(uint8_t mask)   { mmio_write(DIAG_BASE+FWD_CLR, mask&0x3fu); }
void pstate_learn_set(uint8_t mask)   { mmio_write(DIAG_BASE+LEARN_SET, mask&0x3fu); }
void pstate_learn_clear(uint8_t mask) { mmio_write(DIAG_BASE+LEARN_CLR, mask&0x3fu); }
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
