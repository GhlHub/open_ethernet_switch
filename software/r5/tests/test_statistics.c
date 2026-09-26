#include "statistics.h"
#include "FreeRTOS.h"
#include "board.h"
#include <assert.h>
#include <setjmp.h>
#include <stdlib.h>
#include <stdio.h>
static jmp_buf done;
static unsigned mode, polls, index, reads;
static uint64_t timestamp;
uint64_t board_timestamp(void) { return ++timestamp; }
uint32_t board_timestamp_hz(void) { return 1000000; }
TickType_t xTaskGetTickCount(void) { return 0; }
int xil_printf(const char *format,...) { (void)format; return 0; }
void vTaskDelayUntil(TickType_t *wake,TickType_t period)
{
    (void)wake; (void)period;timestamp+=250000;
    if (++polls==40) longjmp(done,1);
}
void mmio_write(uintptr_t address,uint32_t value)
{
    assert(address==DIAG_BASE+0x28);index=value;
}
uint32_t mmio_read(uintptr_t address)
{
    if (address==DIAG_BASE+0x34) return 125000000;
    if (address==DIAG_BASE+0x24) return mode==1?0:0x53540107;
    if (address==DIAG_BASE+0x28) return mode==3?0x32:index;
    if (address==DIAG_BASE+0x30) return mode==3?2:0;
    assert(address==DIAG_BASE+0x2c);reads++;
    if (mode==2 && reads==1) return UINT32_MAX;
    if (mode==4 && polls==0 && index==0x85) return UINT32_MAX;
    if (index==0) return 0x07ffffff;
    if (index==1 && polls==0) return 0x87ffffff;
    if (index==0x83) return polls==0?9:4;
    if (index>=0x80 && index<0xc0) return 3;
    if (index>=0xc0) return 2;
    return 0;
}
int main(int argc,char **argv)
{
    mode=argc>1?(unsigned)atoi(argv[1]):0;
    if (!setjmp(done)) statistics_task(NULL);
    struct statistics_snapshot snapshot;statistics_get(&snapshot);
    assert(snapshot.fabric_hz==125000000);
    assert(snapshot.available==(mode!=1));
    if (mode==1) {assert(reads==0);puts("PASS: firmware capability mismatch rejects collection");return 0;}
    assert(snapshot.polls==40);
    unsigned release_sum=0,response_sum=0;
    for (unsigned bank=0;bank<13;bank++) for (unsigned slot=0;slot<16;slot++) {
        release_sum+=snapshot.release_timeout_by_index[bank][slot];
        response_sum+=snapshot.response_timeout_by_index[bank][slot];
    }
    assert(release_sum==snapshot.mailbox_release_timeouts);
    assert(response_sum==snapshot.snapshot_response_timeouts);
    if (mode==4) {
        assert(snapshot.read_timeouts==1 && snapshot.response_timeout_by_index[8][5]==1);
        assert(snapshot.last_response_index==0x85);
        assert(snapshot.last_release_index==UINT32_MAX);
        puts("PASS: nonzero bank/slot timeout attribution and retry");return 0;
    }
    assert(snapshot.read_timeouts==snapshot.mailbox_release_timeouts+snapshot.snapshot_response_timeouts);
    if (mode==3) {
        assert(reads==0 && snapshot.read_timeouts==40);
        assert(snapshot.mailbox_release_timeouts==40);
        assert(snapshot.snapshot_response_timeouts==0);
        assert(snapshot.release_timeout_by_index[3][2]==40);
        assert(snapshot.last_release_index==0x32 && snapshot.last_release_target_index==0);
        assert(snapshot.last_response_index==UINT32_MAX);
        puts("PASS: stuck mailbox release is bounded and reported");return 0;
    }
    assert(snapshot.port[0][0]==40ULL*0x07ffffff);
    assert(snapshot.read_timeouts==(mode==2));
    assert(snapshot.mailbox_release_timeouts==0);
    assert(snapshot.last_release_index==UINT32_MAX && snapshot.last_release_target_index==UINT32_MAX);
    assert(snapshot.last_response_index==(mode==2?0:UINT32_MAX));
    assert(snapshot.snapshot_response_timeouts==(mode==2));
    assert(snapshot.saturated_reads==(mode==0));
    assert(snapshot.ddr[0][3]==(mode==0?9:4));
    assert(snapshot.ddr[0][0]==(mode==0?40:39)*3u);
    assert(snapshot.debug[0]==(mode==0?40:39)*2u);
    puts("PASS: firmware 64-bit totals, maxima, saturation reporting and timeout recovery");
}
