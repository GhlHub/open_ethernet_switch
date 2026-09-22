#include "board.h"
#include "statistics.h"
#include "FreeRTOS.h"
#include "task.h"
#include "xil_printf.h"
#define CAPS (DIAG_BASE+0x24)
#define INDEX (DIAG_BASE+0x28)
#define DATA (DIAG_BASE+0x2c)
#define BUSY (DIAG_BASE+0x30)
#define EXPECTED_CAPS (0x53540101u | (STATS_DDR<<1) | (STATS_DEBUG<<2))
static struct statistics_snapshot totals={
    .last_release_index=UINT32_MAX, .last_release_target_index=UINT32_MAX,
    .last_response_index=UINT32_MAX
};
static int pending=-1;
void statistics_get(struct statistics_snapshot *out)
{
    taskENTER_CRITICAL(); *out=totals; taskEXIT_CRITICAL();
}
static void accumulate(unsigned index,uint32_t value)
{
    unsigned bank=index>>4, slot=index&15;
    uint64_t *p=NULL;
    if (bank<4 && slot<4) p=&totals.port[bank/2][(bank%2)*4+slot];
    else if (bank>=4 && bank<8 && slot<8) p=&totals.port[bank-2][slot];
#if STATS_DDR
    else if (bank>=8 && bank<12 && slot<8) p=&totals.ddr[bank-8][slot];
#endif
#if STATS_DEBUG
    else if (bank==12) p=&totals.debug[slot];
#endif
    if (!p) return;
    taskENTER_CRITICAL();
    if (value&0x80000000u) totals.saturated_reads++;
    value &= 0x7fffffffu;
    if (bank>=8 && bank<12 && slot==3) {
        if (value>*p) *p=value;
    } else *p+=value;
    taskEXIT_CRITICAL();
}
static bool read_counter(unsigned index)
{
    if (pending<0) {
        uint64_t start=board_timestamp();
        while (mmio_read(BUSY))
            if (board_timestamp()-start > board_timestamp_hz()/10000u) {
                totals.read_timeouts++;
                totals.mailbox_release_timeouts++;
                unsigned active=mmio_read(INDEX)&0xffu;
                totals.last_release_index=active;
                totals.last_release_target_index=index;
                if ((active>>4)<13) totals.release_timeout_by_index[active>>4][active&15]++;
                return false;
            }
        mmio_write(INDEX,index);
    }
    uint32_t value=mmio_read(DATA);
    if (value==UINT32_MAX) {
        pending=(int)index;
        totals.read_timeouts++;
        totals.snapshot_response_timeouts++;
        totals.last_response_index=index;
        totals.response_timeout_by_index[index>>4][index&15]++;
        return false;
    }
    pending=-1;
    accumulate(index,value);
    return true;
}
void statistics_task(void *unused)
{
    (void)unused;
    totals.capabilities=mmio_read(CAPS);
    totals.available=totals.capabilities==EXPECTED_CAPS;
    xil_printf("Statistics ABI/caps %08x expected %08x: %s\r\n",totals.capabilities,
               EXPECTED_CAPS,totals.available?"250 ms polling":"MISMATCH; collection disabled");
    TickType_t wake=xTaskGetTickCount();
    for (;;) {
        uint64_t now=board_timestamp();
        if (totals.timestamp && now-totals.timestamp > board_timestamp_hz()/2u) totals.late_polls++;
        if (totals.available) {
            bool ok=pending<0 || read_counter((unsigned)pending);
            for (unsigned bank=0;bank<13 && ok;bank++) {
                if (bank>=8 && bank<12 && !STATS_DDR) continue;
                if (bank==12 && !STATS_DEBUG) continue;
                unsigned count=bank<4?4:(bank==12?16:8);
                for (unsigned slot=0;slot<count && ok;slot++) ok=read_counter(bank*16+slot);
            }
            totals.polls++;
        }
        taskENTER_CRITICAL(); totals.timestamp=now; taskEXIT_CRITICAL();
        vTaskDelayUntil(&wake,pdMS_TO_TICKS(250));
    }
}
