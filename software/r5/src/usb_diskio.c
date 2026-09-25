#include "usb_storage.h"
#include "ff.h"
#include "diskio.h"
DSTATUS disk_status(BYTE drive) {return !drive && usb_storage_ready()?0:STA_NOINIT|STA_NODISK;}
DSTATUS disk_initialize(BYTE drive) {return disk_status(drive);}
DRESULT disk_read(BYTE drive,BYTE *buffer,LBA_t sector,UINT count)
{
    if (drive || !count) return RES_PARERR;
    while (count) {
        unsigned n=count>128?128:count;
        if (!usb_storage_blocks(sector,n,buffer,false)) return RES_ERROR;
        sector+=n;buffer+=n*512;count-=n;
    }
    return RES_OK;
}
DRESULT disk_write(BYTE drive,const BYTE *buffer,LBA_t sector,UINT count)
{
    if (drive || !count) return RES_PARERR;
    while (count) {
        unsigned n=count>128?128:count;
        if (!usb_storage_blocks(sector,n,(void *)buffer,true)) return RES_ERROR;
        sector+=n;buffer+=n*512;count-=n;
    }
    return RES_OK;
}
DRESULT disk_ioctl(BYTE drive,BYTE command,void *buffer)
{
    if (drive) return RES_PARERR;
    if (!usb_storage_ready()) return RES_NOTRDY;
    switch (command) {
    case CTRL_SYNC:return usb_storage_sync()?RES_OK:RES_ERROR;
    case GET_SECTOR_COUNT:*(LBA_t *)buffer=usb_storage_sectors();return RES_OK;
    case GET_SECTOR_SIZE:*(WORD *)buffer=512;return RES_OK;
    case GET_BLOCK_SIZE:*(DWORD *)buffer=1;return RES_OK;
    default:return RES_PARERR;
    }
}
