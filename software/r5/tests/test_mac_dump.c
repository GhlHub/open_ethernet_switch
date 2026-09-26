#include "mac_dump.h"
#include <assert.h>
#include <stdio.h>
static uint32_t regs[8], flushes, invalidates, sequence, flush_sequence;
uint32_t mmio_read(uintptr_t p) { assert(p>=MAC_DUMP_BASE && p<MAC_DUMP_BASE+32); return regs[(p-MAC_DUMP_BASE)/4]; }
void mmio_write(uintptr_t p, uint32_t value)
{
    assert(p == MAC_DUMP_BASE+4 || p == MAC_DUMP_BASE+8);
    assert(flush_sequence && flush_sequence < ++sequence);
    regs[(p-MAC_DUMP_BASE)/4]=value;
    if (p == MAC_DUMP_BASE+8) {
        assert(regs[1]==0x22000000 && value==1);
        regs[3]=1;regs[4]=regs[5]=0;
    }
}
void barrier(void) { ++sequence; }
void Xil_DCacheFlushRange(uintptr_t p, uint32_t len)
{ assert(p==0x22000000 && len==32768); ++flushes;flush_sequence=++sequence; }
void Xil_DCacheInvalidateRange(uintptr_t p, uint32_t len)
{ assert(p==0x22000000 && len==32768 && !(regs[3]&1) && (regs[3]&2)); ++invalidates; }
int main(void)
{
    struct mac_dump_record *buffer=(void *)0x22000000;
    uint32_t bytes=99,error=99;
    assert(mac_dump_poll(&bytes,&error)==MAC_DUMP_IDLE);
    assert(mac_dump_start(NULL,32768)==MAC_DUMP_BAD_BUFFER);
    assert(mac_dump_start((void *)0x22000001,32768)==MAC_DUMP_BAD_BUFFER);
    assert(mac_dump_start((void *)0x7fff8100,32768)==MAC_DUMP_BAD_BUFFER);
    assert(mac_dump_start(buffer,32767)==MAC_DUMP_BAD_BUFFER);
    assert(mac_dump_start(buffer,32768)==MAC_DUMP_UNAVAILABLE);
    regs[0]=0x4d445001;regs[3]=1;
    assert(mac_dump_start(buffer,32768)==MAC_DUMP_BUSY);
    assert(flushes==0);
    regs[3]=0;
    assert(mac_dump_start(buffer,32768)==MAC_DUMP_STARTED);
    assert(flushes==1 && invalidates==0);
    assert(mac_dump_start(buffer,32768)==MAC_DUMP_BUSY);
    for(int i=0;i<1000;i++)assert(mac_dump_poll(&bytes,&error)==MAC_DUMP_BUSY);
    assert(bytes==99 && error==99 && invalidates==0 && flushes==1);
    /* A status without BUSY or DONE is not proof DMA relinquished ownership. */
    regs[3]=0;assert(mac_dump_poll(NULL,NULL)==MAC_DUMP_BUSY);
    assert(mac_dump_start(buffer,32768)==MAC_DUMP_BUSY);
    regs[3]=2;regs[4]=32768;
    assert(mac_dump_poll(&bytes,&error)==MAC_DUMP_DONE);
    assert(bytes==32768 && error==0 && invalidates==1);
    assert(mac_dump_poll(NULL,NULL)==MAC_DUMP_IDLE);
    assert(mac_dump_start(buffer,32768)==MAC_DUMP_STARTED);
    regs[3]=6;regs[4]=256;regs[5]=1;
    assert(mac_dump_poll(&bytes,&error)==MAC_DUMP_ERROR);
    assert(bytes==256 && error==1 && invalidates==2 && flushes==2);
    puts("PASS: MAC dump cache and DMA ownership, validation, completion and error");
}
