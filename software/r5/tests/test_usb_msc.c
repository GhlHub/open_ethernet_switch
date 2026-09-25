#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../../../third_party/libpayload_usb/drivers/usbmsc.c"
static unsigned phase,command,tag_seen,resets,data_size;
static bool short_data,short_cbw,bad_tag,sync_failed,valid_sense,mode_fail;
static unsigned residual,mode_case,sense_key=5;
static int fake_bulk(endpoint_t *ep,int n,u8 *buf,int final)
{
    (void)ep;(void)final;
    if (phase==0) {
        assert(n==31);cbw_t cb;memcpy(&cb,buf,sizeof(cb));assert(cb.dCBWSignature==cbw_signature);
        command=cb.CBWCB[0];tag_seen=cb.dCBWTag;data_size=cb.dCBWDataTransferLength;
        if (short_cbw) return n-1;
        residual=0;phase=data_size?1:2;return n;
    }
    if (phase==1) {
        assert((unsigned)n==data_size);memset(buf,0xa5,n);phase=2;
        if (valid_sense && command==3) {
            memset(buf,0,n);buf[0]=0x70;buf[2]=sense_key;buf[7]=10;buf[12]=0x20;
            residual=n-18;return 18;
        }
        if (command==0x1a) {
            memset(buf,0,n);buf[0]=35;buf[4]=5;buf[5]=30;
            if (mode_case==1 || mode_case==2) {buf[0]=23;buf[4]=8;buf[5]=18;buf[6]=mode_case==2?4:0;}
            if (mode_case==3) buf[5]=80;
            if (mode_case==5) buf[2]=0x80;
            unsigned len=mode_case==4?20:buf[0]+1;residual=n-len;return len;
        }
        return short_data?n-1:n;
    }
    assert(n==13);csw_t cs={0};cs.dCSWSignature=csw_signature;cs.dCSWTag=tag_seen+(bad_tag?1:0);
    cs.dCSWDataResidue=residual;cs.bCSWStatus=(sync_failed && command==0x35)||(mode_fail && command==0x1a)?1:0;memcpy(buf,&cs,sizeof(cs));phase=0;return n;
}
static int fake_control(usbdev_t *dev,direction_t dir,int n,void *req,int len,u8 *data)
{(void)dev;(void)dir;(void)n;(void)req;(void)len;(void)data;resets++;phase=0;return 0;}
int clear_stall(endpoint_t *ep) {(void)ep;return 0;}
void usb_detach_device(hci_t *hc,int dev) {(void)hc;(void)dev;assert(0);}
int main(void)
{
    _Static_assert(sizeof(cbw_t)==31,"CBW wire layout");_Static_assert(sizeof(csw_t)==13,"CSW wire layout");
    hci_t host={.bulk=fake_bulk,.control=fake_control};usbdev_t dev={.controller=&host};
    endpoint_t in={.dev=&dev},out={.dev=&dev};usbmsc_inst_t state={.blocksize=512,.numblocks=100,.bulk_in=&in,.bulk_out=&out};dev.data=&state;
    u8 data[512];assert(!readwrite_blocks(&dev,1,1,cbw_direction_data_in,data));assert(command==0x28&&data[0]==0xa5);
    assert(!readwrite_blocks(&dev,1,1,cbw_direction_data_out,data));assert(command==0x2a);
    assert(!usb_msc_sync(&dev)&&command==0x35);
    short_data=true;assert(readwrite_blocks(&dev,1,1,cbw_direction_data_in,data));short_data=false;
    short_cbw=true;assert(readwrite_blocks(&dev,1,1,cbw_direction_data_out,data));short_cbw=false;assert(resets==1);
    bad_tag=true;assert(usb_msc_sync(&dev));bad_tag=false;assert(resets==2);
    sync_failed=true;assert(usb_msc_sync(&dev));
    valid_sense=true;assert(usb_msc_sync(&dev)); /* unknown device */
    device_descriptor_t desc={.idVendor=0x0424,.idProduct=0x2240};dev.descriptor=&desc;
    assert(!usb_msc_sync(&dev)); /* confirmed unsupported sync, absent cache */
    mode_case=1;assert(!usb_msc_sync(&dev)); /* explicitly disabled cache */
    for (mode_case=2;mode_case<=5;mode_case++) assert(usb_msc_sync(&dev));
    mode_case=0;sense_key=3;assert(usb_msc_sync(&dev)); /* medium error */
    sense_key=5;mode_fail=true;assert(usb_msc_sync(&dev));
    puts("PASS: USB MSC read/write/flush, short transfers, malformed status, failed flush and guarded USB2244 write-through policy");
}
