#include "board.h"
#include "statistics.h"
#include "FreeRTOS.h"
#include "task.h"
#include "xsysmonpsu.h"
#include "xiicps.h"
#include "xil_printf.h"
#include <string.h>
#define AMS 0xffa50000UL
#define IIC 0xff030000UL
static struct sensor_snapshot latest;
static XSysMonPsu sysmon;
static XIicPs iic;
static bool iic_ready;
static unsigned monitor_mask;
void sensors_get(struct sensor_snapshot *out)
{
    taskENTER_CRITICAL(); *out=latest; taskEXIT_CRITICAL();
}
static bool expired(uint64_t start)
{
    return board_timestamp()-start > board_timestamp_hz()/500u; /* 2 ms */
}
/* Short polled transactions, bounded even if a sensor or bus fails. */
static bool iic_transfer(uint8_t *bytes,unsigned count,bool receive)
{
    if (!iic_ready || (mmio_read(IIC+XIICPS_SR_OFFSET)&XIICPS_SR_BA_MASK)) return false;
    uint32_t control=mmio_read(IIC+XIICPS_CR_OFFSET)&(XIICPS_CR_DIV_A_MASK|XIICPS_CR_DIV_B_MASK);
    control |= XIICPS_CR_ACKEN_MASK|XIICPS_CR_NEA_MASK|XIICPS_CR_MS_MASK;
    mmio_write(IIC+XIICPS_CR_OFFSET,control|XIICPS_CR_CLR_FIFO_MASK|(receive?XIICPS_CR_RD_WR_MASK:0));
    mmio_write(IIC+XIICPS_ISR_OFFSET,XIICPS_IXR_ALL_INTR_MASK);
    if (receive) mmio_write(IIC+XIICPS_TRANS_SIZE_OFFSET,count);
    else for (unsigned i=0;i<count;i++) mmio_write(IIC+XIICPS_DATA_OFFSET,bytes[i]);
    mmio_write(IIC+XIICPS_ADDR_OFFSET,0x40);
    uint64_t start=board_timestamp();
    for (;;) {
        uint32_t status=mmio_read(IIC+XIICPS_ISR_OFFSET);
        if ((status&(XIICPS_IXR_ARB_LOST_MASK|XIICPS_IXR_TO_MASK|XIICPS_IXR_NACK_MASK|
                     XIICPS_IXR_RX_UNF_MASK|XIICPS_IXR_TX_OVR_MASK|XIICPS_IXR_RX_OVR_MASK)) || expired(start)) {
            mmio_write(IIC+XIICPS_CR_OFFSET,control|XIICPS_CR_CLR_FIFO_MASK);
            return false;
        }
        if ((status&XIICPS_IXR_COMP_MASK) && !(mmio_read(IIC+XIICPS_SR_OFFSET)&XIICPS_SR_BA_MASK)) break;
    }
    if (receive) for (unsigned i=0;i<count;i++) {
        if (!(mmio_read(IIC+XIICPS_SR_OFFSET)&XIICPS_SR_RXDV_MASK)) return false;
        bytes[i]=(uint8_t)mmio_read(IIC+XIICPS_DATA_OFFSET);
    }
    return true;
}
/* INA260 retains its pointer across STOP. The sensor task owns PS I2C1. */
static bool ina_read(unsigned reg,uint16_t *value)
{
    uint8_t pointer=(uint8_t)reg, data[2];
    if (!iic_transfer(&pointer,1,false) || !iic_transfer(data,2,true)) return false;
    *value=(uint16_t)((data[0]<<8)|data[1]);
    return true;
}
static bool ina_start(void)
{
    uint16_t manufacturer, device, config;
    if (!ina_read(0xfe,&manufacturer) || manufacturer!=0x5449 ||
        !ina_read(0xff,&device) || (device&0xfff0)!=0x2270 || !ina_read(0,&config)) return false;
    // 16-sample averaging, 1.1 ms current and voltage, continuous conversion.
    // Reserved bits retain the read value; reset bit is never asserted.
    uint16_t desired=(uint16_t)((config&0x7000u)|0x0527u);
    if (config==desired) return true;
    uint8_t data[3]={0,(uint8_t)(desired>>8),(uint8_t)desired};
    (void)iic_transfer(data,3,false);
    return false; // publish only after a completed conversion on the next poll
}
static void monitor_init(void)
{
    /* Attach to the hard AMS blocks without resetting boot-established alarm
     * thresholds/protection. CfgInitialize resets AMS and waits unboundedly.
     * Only the sequencer/channel/divisor configuration is changed here. */
    XSysMonPsu_Config *cfg=XSysMonPsu_LookupConfig(AMS);
    if (!cfg) return;
    XSysMonPsu_InitInstance(&sysmon,cfg);
    sysmon.Config=*cfg;
    sysmon.IsPlAccessibleByPs=mmio_read(AMS+XSYSMONPSU_PL_SYSMON_CSTS_OFFSET)&1u;
    for (unsigned b=0;b<2;b++) {
        unsigned block=b?XSYSMON_PL:XSYSMON_PS;
        if (b && !sysmon.IsPlAccessibleByPs) continue;
        if (monitor_mask&(1u<<b)) continue;
        uint32_t ps_status=mmio_read(AMS+XSYSMONPSU_PS_SYSMON_CSTS_OFFSET);
        if (!b && !(ps_status&XSYSMONPSU_PS_SYSMON_CSTS_STRTUP_DNE_MASK)) {
            mmio_write(AMS+XSYSMONPSU_PS_SYSMON_CSTS_OFFSET,ps_status|XSYSMONPSU_PS_SYSMON_CSTS_STRTUP_TRIG_MASK);
            continue;
        }
        uint8_t divisor;
        if (XSysMonPsu_UpdateAdcClkDivisor(&sysmon,block,&divisor)!=XST_SUCCESS) continue;
        uint64_t existing=XSysMonPsu_GetSeqChEnables(&sysmon,block);
        XSysMonPsu_SetSequencerMode(&sysmon,XSM_SEQ_MODE_SAFE,block);
        uint64_t channels=XSYSMONPSU_SEQ_CH0_CALIBRTN_MASK|XSYSMONPSU_SEQ_CH0_TEMP_MASK|
            XSYSMONPSU_SEQ_CH0_SUP1_MASK|XSYSMONPSU_SEQ_CH0_SUP2_MASK|XSYSMONPSU_SEQ_CH0_SUP3_MASK;
        if (XSysMonPsu_SetSeqChEnables(&sysmon,channels|existing,block)!=XST_SUCCESS) continue;
        XSysMonPsu_SetSequencerMode(&sysmon,XSM_SEQ_MODE_CONTINPASS,block);
        if (XSysMonPsu_GetSequencerMode(&sysmon,block)==XSM_SEQ_MODE_CONTINPASS) monitor_mask |= 1u<<b;
    }
    if (monitor_mask&1) XSysMonPsu_SetPSAutoConversion(&sysmon);
}
void sensors_task(void *unused)
{
    (void)unused;
    monitor_init();
    XIicPs_Config *cfg=XIicPs_LookupConfig(IIC);
    if (cfg && XIicPs_CfgInitialize(&iic,cfg,IIC)==XST_SUCCESS) {
        XIicPs_DisableAllInterrupts(IIC);
        iic_ready=XIicPs_SetSClk(&iic,100000)==XST_SUCCESS;
    }
    xil_printf("Sensors: AMS blocks %x, PS I2C1 %s; INA260 at 0x40 (SOM power)\r\n",
               monitor_mask,iic_ready?"ready":"unavailable");
    TickType_t wake=xTaskGetTickCount();
    for (;;) {
        vTaskDelayUntil(&wake,pdMS_TO_TICKS(1000));
        struct sensor_snapshot sample=latest;
        sample.valid_mask=0;
        if (monitor_mask!=3) monitor_init();
        for (unsigned b=0;b<2;b++) {
            if (!(monitor_mask&(1u<<b))) continue;
            unsigned block=b?XSYSMON_PL:XSYSMON_PS;
            uint16_t raw=XSysMonPsu_GetAdcData(&sysmon,XSM_CH_TEMP,block);
            bool valid=raw!=0 && raw!=0xffff;
            sample.temperature_mc[b]=(int32_t)(XSysMonPsu_RawToTemperature_OnChip(raw)*1000.0f);
            const uint8_t channel[]={XSM_CH_SUPPLY1,XSM_CH_SUPPLY2,XSM_CH_SUPPLY3};
            for (unsigned j=0;j<3;j++) {
                raw=XSysMonPsu_GetAdcData(&sysmon,channel[j],block);
                valid=valid && raw!=0 && raw!=0xffff;
                sample.voltage_uv[b][j]=(uint32_t)(((uint64_t)raw*3000000u)/65536u);
            }
            if (valid) sample.valid_mask |= 1u<<b;
            else sample.errors++;
        }
        uint16_t flags,current,voltage,power;
        if (ina_start() && ina_read(6,&flags) && (flags&0x0cu)==8u &&
            ina_read(1,&current) && ina_read(2,&voltage) && ina_read(3,&power)) {
            sample.som_current_ua=(int32_t)(int16_t)current*1250;
            sample.som_voltage_uv=(uint32_t)voltage*1250;
            sample.som_power_uw=(uint32_t)power*10000;
            sample.valid_mask |= 4;
        } else sample.errors++;
        sample.timestamp=board_timestamp();
        taskENTER_CRITICAL(); latest=sample; taskEXIT_CRITICAL();
    }
}
