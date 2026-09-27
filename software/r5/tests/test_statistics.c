#include "statistics.h"
#include "FreeRTOS.h"
#include "board.h"
#include <assert.h>
#include <setjmp.h>
#include <stdlib.h>
#include <stdio.h>
static jmp_buf done;
static unsigned mode, polls, index, reads;
static uint64_t timestamp=1;
static uint32_t counter[13][16], saved[13];
static int pending[13];
static bool ready[13], fault_sent;
static unsigned slots(unsigned b) { return b<4?4:b==12?16:8; }
static bool clock_up(unsigned b)
{
    return b!=2 || !((mode==2 && polls>=1 && polls<6) || (mode==5 && polls<6));
}
uint64_t board_timestamp(void) { return ++timestamp; }
uint32_t board_timestamp_hz(void) { return 1000000; }
TickType_t xTaskGetTickCount(void) { return 0; }
int xil_printf(const char *format,...) { (void)format; return 0; }
void vTaskDelayUntil(TickType_t *wake,TickType_t period)
{
    (void)wake; (void)period;timestamp+=250000;
    if (++polls==40) longjmp(done,1);
    for (unsigned b=0;b<13;b++) if(clock_up(b)) {
        for (unsigned i=0;i<slots(b);i++) counter[b][i]++;
        if (pending[b]>=0 && !ready[b]) {
            saved[b]=counter[b][pending[b]];counter[b][pending[b]]=0;ready[b]=true;
        }
    }
}
void mmio_write(uintptr_t address,uint32_t value)
{
    assert(address==DIAG_BASE+0x28);index=value;
}
uint32_t mmio_read(uintptr_t address)
{
    unsigned b=index>>4, slot=index&15;
    if (address==DIAG_BASE+0x34) return 125000000;
    if (address==DIAG_BASE+0x24) return mode==1?0:(0x53540201u|(STATS_DDR<<1)|(STATS_DEBUG<<2));
    if (address==DIAG_BASE+0x38) {
        uint32_t s=clock_up(b)?8:0;
        if(pending[b]>=0) s|=1u|((unsigned)pending[b]<<4)|(ready[b]?2u:0);
        if(mode==3 && b==2 && polls==0) s|=4; // release stuck, clock running
        if(mode==2 && b==2 && fault_sent && polls==0) s|=0x100; // gap seen during read
        return s;
    }
    assert(address==DIAG_BASE+0x2c);reads++;
    if(mode==3 && b==2 && polls==0) return UINT32_MAX;
    if((mode==2 || mode==4) && b==2 && slot==1 && !fault_sent) {
        pending[b]=(int)slot;fault_sent=true;return UINT32_MAX;
    }
    uint32_t value;
    if(pending[b]>=0) {
        assert(pending[b]==(int)slot); // never retarget a destructive read
        if(!ready[b]) return UINT32_MAX;
        value=saved[b];pending[b]=-1;ready[b]=false;
    } else {
        assert(clock_up(b));value=counter[b][slot];counter[b][slot]=0;
    }
    return value;
}
int main(int argc,char **argv)
{
    mode=argc>1?(unsigned)atoi(argv[1]):0;
    for(unsigned b=0;b<13;b++) {
        pending[b]=-1;
        for(unsigned i=0;i<slots(b);i++) counter[b][i]=100+b*16+i;
    }
    // Captured before firmware starts, source clock now stopped.
    if(mode==5) {pending[2]=3;ready[2]=true;saved[2]=counter[2][3];counter[2][3]=0;}
    if (!setjmp(done)) statistics_task(NULL);
    struct statistics_snapshot s;statistics_get(&s);
    assert(s.fabric_hz==125000000 && s.available==(mode!=1));
    if(mode==1) {assert(reads==0);puts("PASS: ABI mismatch disables collection");return 0;}
    assert(s.polls==40 && s.bank[2].state==1 && s.bank[2].last_success);
    // Every additive total is exact, including the stopped bank, while healthy
    // banks collected throughout. No clear is lost or counted twice.
    for(unsigned b=0;b<4;b++) for(unsigned i=0;i<4;i++) {
        unsigned increments=39;
        if(b==2 && mode==2) increments-=5;
        if(b==2 && mode==5) increments-=5;
        assert(s.port[b/2][(b%2)*4+i]==100+b*16+i+increments);
    }
    for(unsigned b=4;b<8;b++) for(unsigned i=0;i<8;i++)
        assert(s.port[b-2][i]==100+b*16+i+39);
#if STATS_DEBUG
    assert(s.debug[0]==100+12*16+39);
#else
    assert(s.bank[12].state==0);
#endif
#if STATS_DDR
    assert(s.ddr[0][0]==100+8*16+39);
    assert(s.ddr[0][3]==100+8*16+3);
#else
    assert(s.bank[8].state==0 && s.bank[11].state==0);
#endif
    assert(s.bank[2].clock_unavailable_events==((mode==2 || mode==5)?1u:0u));
    assert(s.read_timeouts==((mode==3 || mode==4)?1u:0u));
    assert(s.mailbox_release_timeouts==(mode==3));
    assert(s.snapshot_response_timeouts==(mode==4));
    assert(s.bank[2].active_clock_timeouts==s.read_timeouts);
    if(mode==3) assert(s.release_timeout_by_index[2][0]==1);
    if(mode==4) assert(s.response_timeout_by_index[2][1]==1 && s.last_response_index==0x21);
    assert(s.bank[7].last_success);
    puts("PASS: independent banks, exact accumulation, stopped-clock retry, fault classification and pending-result recovery");
    return 0;
}
