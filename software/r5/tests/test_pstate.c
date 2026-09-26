/* Plumbing-only test: each pstate.c call writes/reads the register offset
 * board.h defines for it, packed the way rx_diag_regs.sv expects, and
 * cpu_tx_raw passes per-frame metadata to the serialized DMA sender.
 * Not a protocol test -- there is no protocol here to test. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../src/pstate.c"
static struct {uintptr_t addr;uint32_t value;} regs[16];
static unsigned nregs;
uint32_t mmio_read(uintptr_t a)
{
    for (unsigned i=0;i<nregs;i++) if (regs[i].addr==a) return regs[i].value;
    return 0;
}
void mmio_write(uintptr_t a,uint32_t v)
{
    for (unsigned i=0;i<nregs;i++) if (regs[i].addr==a) {regs[i].value=v;return;}
    assert(nregs<16); regs[nregs].addr=a; regs[nregs++].value=v;
}
static uint8_t sent_mask;
static const uint8_t *sent_frame; static size_t sent_len; static bool sent_ok=true;
bool fabric_dma_send_directed(const uint8_t *p,size_t n,uint8_t mask){sent_mask=mask;sent_frame=p;sent_len=n;return sent_ok;}
int main(void)
{
    pstate_fwd_set(0x15);   assert(mmio_read(DIAG_BASE+FWD_SET)==0x15);
    pstate_fwd_clear(0x2a); assert(mmio_read(DIAG_BASE+FWD_CLR)==0x2a);
    pstate_learn_set(0x01);   assert(mmio_read(DIAG_BASE+LEARN_SET)==0x01);
    pstate_learn_clear(0x3f); assert(mmio_read(DIAG_BASE+LEARN_CLR)==0x3f);

    /* out-of-range bits (only 6 ports exist) are masked off before the write */
    pstate_fwd_set(0xff); assert(mmio_read(DIAG_BASE+FWD_SET)==0x3f);

    mmio_write(DIAG_BASE+PORT_CTRL_STATUS,(0x2au<<8)|0x15u);
    uint8_t fwd=0,learn=0; pstate_get(&fwd,&learn);
    assert(fwd==0x15 && learn==0x2a);

    uint8_t frame[]={1,2,3,4,5};
    assert(pstate_cpu_tx_raw(0x04,frame,sizeof frame));
    assert(sent_mask==4);
    assert(sent_frame==frame && sent_len==sizeof frame);

    sent_ok=false;
    assert(!pstate_cpu_tx_raw(0x01,frame,sizeof frame)); /* propagates DMA failure */

    /* the default weak hook exists, is callable, and has no observable effect */
    nregs=0; fabric_ctrl_frame_rx(frame,sizeof frame); assert(nregs==0);

    printf("PASS: pstate register plumbing (FWD/LEARN set-clear, status unpack, CPU TX override, default RX hook)\n");
    return 0;
}
