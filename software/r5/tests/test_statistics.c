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
    if (address==DIAG_BASE+0x24) return mode==1?0:0x53540107;
    if (address==DIAG_BASE+0x30) return mode==3?2:0;
    assert(address==DIAG_BASE+0x2c);reads++;
    if (mode==2 && reads==1) return UINT32_MAX;
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
    assert(snapshot.available==(mode!=1));
    if (mode==1) {assert(reads==0);puts("PASS: firmware capability mismatch rejects collection");return 0;}
    assert(snapshot.polls==40);
    if (mode==3) {
        assert(reads==0 && snapshot.read_timeouts==40);
        puts("PASS: stuck mailbox release is bounded and reported");return 0;
    }
    assert(snapshot.port[0][0]==40ULL*0x07ffffff);
    assert(snapshot.read_timeouts==(mode==2));
    assert(snapshot.saturated_reads==(mode==0));
    assert(snapshot.ddr[0][3]==(mode==0?9:4));
    assert(snapshot.ddr[0][0]==(mode==0?40:39)*3u);
    assert(snapshot.debug[0]==(mode==0?40:39)*2u);
    puts("PASS: firmware 64-bit totals, maxima, saturation reporting and timeout recovery");
}
