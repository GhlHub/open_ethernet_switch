#include "settings_media.h"
#include "usb_storage.h"
#include "config.h"
#include "ff.h"
#include <string.h>
static FATFS volume;
static bool mounted;
static const char *status="not probed";
static const char *const names[]={"0:/KR260A.CFG","0:/KR260B.CFG"};
static bool failed(void) {mounted=false;status="card/file I/O error";return false;}
bool settings_media_present(void)
{
    /* All handles are closed between calls. Remount discards stale FAT cache,
     * including replacement by a different card of exactly the same size. */
    mounted=false;(void)f_mount(NULL,"0:",0);
    if (!usb_storage_probe()) {status="card unavailable";return false;}
    FRESULT r=f_mount(&volume,"0:",1);
    if (r!=FR_OK) {status=r==FR_NO_FILESYSTEM?"FAT volume required":"card mount failed";return false;}
    mounted=true;status="FAT card mounted";return true;
}
static bool bounds(unsigned slot,unsigned offset,size_t size)
{return mounted && usb_storage_ready() && slot<2 && offset<=CONFIG_RECORD_SIZE && size<=CONFIG_RECORD_SIZE-offset;}
bool settings_media_read(unsigned slot,unsigned offset,void *data,size_t size)
{
    if (!bounds(slot,offset,size)) return false;
    memset(data,0xff,size);
    FIL file;FRESULT r=f_open(&file,names[slot],FA_READ);
    if (r==FR_NO_FILE) return true;
    if (r!=FR_OK) return failed();
    if (f_size(&file)>CONFIG_RECORD_SIZE) {
        bool closed=f_close(&file)==FR_OK;
        status="oversized configuration file";
        if (!closed) return failed();
        return false;
    }
    bool ok=true;
    if (ok && offset<f_size(&file)) {
        UINT actual=0;size_t n=f_size(&file)-offset;if (n>size) n=size;
        ok=f_lseek(&file,offset)==FR_OK && f_read(&file,data,n,&actual)==FR_OK && actual==n;
    }
    if (f_close(&file)!=FR_OK) ok=false;
    return ok?true:failed();
}
bool settings_media_truncate(unsigned slot)
{
    if (!bounds(slot,0,0)) return false;
    FIL file;FRESULT r=f_open(&file,names[slot],FA_WRITE|FA_CREATE_ALWAYS);
    if (r!=FR_OK) return failed();
    bool ok=f_sync(&file)==FR_OK;
    if (f_close(&file)!=FR_OK) ok=false;
    return ok?true:failed();
}
bool settings_media_write(unsigned slot,unsigned offset,const void *data,size_t size)
{
    if (!bounds(slot,offset,size)) return false;
    FIL file;FRESULT r=f_open(&file,names[slot],FA_WRITE);
    if (r!=FR_OK) return failed();
    UINT actual=0;
    bool ok=f_size(&file)<=CONFIG_RECORD_SIZE && f_lseek(&file,offset)==FR_OK &&
        f_write(&file,data,size,&actual)==FR_OK && actual==size && f_sync(&file)==FR_OK;
    if (f_close(&file)!=FR_OK) ok=false;
    return ok?true:failed();
}
const char *settings_media_status(void) {return status;}
