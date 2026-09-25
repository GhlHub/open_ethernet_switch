/* KR260 USB0 -> USB5744 hub -> USB2244 SD reader. No A53 service. */
#include "board.h"
#include "usb_storage.h"
#include "xiicps.h"
#include "xil_printf.h"
#include "xhci.h"
#include <usb/usbmsc.h>
#include <usb/usbdisk.h>
#define USB0 0xfe200000u
#define IIC 0xff030000u
static bool attempted;
static hci_t *host;
static usbdev_t *card;
/* Only run before the sensor task starts: that task subsequently owns I2C1. */
static bool i2c_xfer(unsigned addr,uint8_t *bytes,unsigned n,bool read)
{
    uint32_t cr=mmio_read(IIC+XIICPS_CR_OFFSET)&(XIICPS_CR_DIV_A_MASK|XIICPS_CR_DIV_B_MASK);
    cr|=XIICPS_CR_ACKEN_MASK|XIICPS_CR_NEA_MASK|XIICPS_CR_MS_MASK;
    if (mmio_read(IIC+XIICPS_SR_OFFSET)&XIICPS_SR_BA_MASK) return false;
    mmio_write(IIC+XIICPS_CR_OFFSET,cr|XIICPS_CR_CLR_FIFO_MASK|(read?XIICPS_CR_RD_WR_MASK:0));
    mmio_write(IIC+XIICPS_ISR_OFFSET,XIICPS_IXR_ALL_INTR_MASK);
    if (read) mmio_write(IIC+XIICPS_TRANS_SIZE_OFFSET,n);
    else for (unsigned i=0;i<n;i++) mmio_write(IIC+XIICPS_DATA_OFFSET,bytes[i]);
    mmio_write(IIC+XIICPS_ADDR_OFFSET,addr);
    uint64_t deadline=board_timestamp()+board_timestamp_hz()/100;
    for (;;) {
        uint32_t s=mmio_read(IIC+XIICPS_ISR_OFFSET);
        if ((s&(XIICPS_IXR_ARB_LOST_MASK|XIICPS_IXR_TO_MASK|XIICPS_IXR_NACK_MASK|
                XIICPS_IXR_RX_UNF_MASK|XIICPS_IXR_TX_OVR_MASK|XIICPS_IXR_RX_OVR_MASK)) || board_timestamp()>deadline) {
            mmio_write(IIC+XIICPS_CR_OFFSET,cr|XIICPS_CR_CLR_FIFO_MASK);return false;
        }
        if ((s&XIICPS_IXR_COMP_MASK) && !(mmio_read(IIC+XIICPS_SR_OFFSET)&XIICPS_SR_BA_MASK)) break;
    }
    if (read) for (unsigned i=0;i<n;i++) {
        if (!(mmio_read(IIC+XIICPS_SR_OFFSET)&XIICPS_SR_RXDV_MASK)) return false;
        bytes[i]=mmio_read(IIC+XIICPS_DATA_OFFSET);
    }
    return true;
}
static bool carrier_init(void)
{
    XIicPs iic; XIicPs_Config *cfg=XIicPs_LookupConfig(IIC);
    if (!cfg || XIicPs_CfgInitialize(&iic,cfg,IIC)!=XST_SUCCESS || XIicPs_SetSClk(&iic,100000)!=XST_SUCCESS) return false;
    XIicPs_DisableAllInterrupts(IIC);
    uint8_t reg=0xdb, reset;
    if (!i2c_xfer(0x11,&reg,1,false) || !i2c_xfer(0x11,&reset,1,true)) return false;
    /* Preserve GEM0/GEM1 and USB1 reset bits. Active-low USB0 PHY, SD, hub. */
    uint8_t cmd[]={0xdb,reset&~0x0du};
    if (!i2c_xfer(0x11,cmd,2,false)) return false;
    mdelay(2);cmd[1]=reset|0x0d;
    if (!i2c_xfer(0x11,cmd,2,false)) return false;
    mdelay(10);
    uint8_t mux=1;
    if (!i2c_xfer(0x74,&mux,1,false)) return false;
    uint8_t bypass[]={0,0,5,0,1,0x41,0x1d,8};
    uint8_t access[]={0x99,0x37,0},attach[]={0xaa,0x56,0};
    bool ok=i2c_xfer(0x2d,bypass,sizeof(bypass),false) &&
        i2c_xfer(0x2d,access,sizeof(access),false) && i2c_xfer(0x2d,attach,sizeof(attach),false);
    mux=0;bool closed=i2c_xfer(0x74,&mux,1,false);
    mdelay(20);return ok && closed;
}
static bool controller_init(void)
{
    /* FSBL provides MIO, clocks, GTR and wrapper setup. Release USB0 resets
     * without altering USB1 or other PS peripherals. */
    mmio_write(0xff5e023c,mmio_read(0xff5e023c)&~0x540u);
    uint32_t id=mmio_read(USB0+0xc120);
    if ((id&0xffff0000u)!=0x55330000u) return false;
    uint32_t ctl=mmio_read(USB0+0xc110);
    mmio_write(USB0+0xc110,ctl|(1u<<11));
    mmio_write(USB0+0xc200,mmio_read(USB0+0xc200)|(1u<<31));
    mmio_write(USB0+0xc2c0,mmio_read(USB0+0xc2c0)|(1u<<31));
    mdelay(100);
    mmio_write(USB0+0xc200,mmio_read(USB0+0xc200)&~((1u<<31)|(1u<<6)));
    mmio_write(USB0+0xc2c0,mmio_read(USB0+0xc2c0)&~((1u<<31)|(1u<<17)));
    mdelay(100);
    /* GCTL: host mode, no scaledown/scrambling disable, exit core reset. */
    ctl &= ~((3u<<12)|(3u<<4)|(1u<<3)|(1u<<11)|1u);
    ctl |= 1u<<12;
    if ((id&0xffff)<0x190a) ctl|=1u<<16;
    mmio_write(USB0+0xc110,ctl);
    host=xhci_init(USB0);return host!=NULL;
}
void usbdisk_create(usbdev_t *dev)
{
    /* Do not select an arbitrary USB thumb drive plugged into a front port. */
    if (dev->descriptor->idVendor==0x0424 && dev->descriptor->idProduct==0x2240 &&
        MSC_INST(dev)->blocksize==512 && MSC_INST(dev)->numblocks<=INT32_MAX && !card) {
        card=dev;
        xil_printf("USB SD: card ready, %u sectors\r\n",MSC_INST(dev)->numblocks);
    }
}
void usbdisk_remove(usbdev_t *dev) {if (card==dev) card=NULL;}
bool usb_storage_ready(void) {return card && MSC_INST(card)->ready==USB_MSC_READY;}
bool usb_storage_probe(void)
{
    if (!attempted) {
        attempted=true;
        if (!carrier_init()) {xil_printf("USB SD: carrier reset/hub setup failed\r\n");return false;}
        if (!controller_init()) {xil_printf("USB SD: xHCI setup failed\r\n");return false;}
        xil_printf("USB SD: USB0 host ready, probing onboard reader\r\n");
        /* Hub polling attaches children over successive passes. */
        for (unsigned i=0;i<8 && !card;i++) {usb_poll();mdelay(100);}
    }
    else if (host) usb_poll();
    return usb_storage_ready();
}
uint32_t usb_storage_sectors(void) {return usb_storage_ready()?MSC_INST(card)->numblocks:0;}
bool usb_storage_blocks(uint32_t lba,unsigned count,void *data,bool write)
{
    uint32_t sectors=usb_storage_sectors();
    if (!count || count>128 || lba>=sectors || count>sectors-lba) return false;
    return readwrite_blocks(card,(int)lba,(int)count,write?cbw_direction_data_out:cbw_direction_data_in,data)==0;
}
bool usb_storage_sync(void) {return usb_storage_ready() && usb_msc_sync(card)==0;}
