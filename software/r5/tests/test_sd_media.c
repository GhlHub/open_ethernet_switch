/* Real FatFs and settings provider over a disposable RAM disk, no card writes. */
#include "usb_storage.h"
#include "settings_media.h"
#include "config.h"
#include "ff.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define SECTORS 16384
static unsigned char disk[SECTORS*512];
static bool present=true, fail_write, fail_sync;
static unsigned writes;
bool usb_storage_probe(void) {return present;}
bool usb_storage_ready(void) {return present;}
uint32_t usb_storage_sectors(void) {return present?SECTORS:0;}
bool usb_storage_sync(void) {return present && !fail_sync;}
bool usb_storage_blocks(uint32_t lba,unsigned count,void *buf,bool write)
{
    if (!present || lba>=SECTORS || count>SECTORS-lba || (write && fail_write)) return false;
    if (write) {memcpy(disk+lba*512,buf,count*512);writes++;}
    else memcpy(buf,disk+lba*512,count*512);
    return true;
}
static void le16(unsigned offset,unsigned v) {disk[offset]=v;disk[offset+1]=v>>8;}
static void format_fixture(void)
{
    memset(disk,0,sizeof(disk));disk[0]=0xeb;disk[1]=0x3c;disk[2]=0x90;
    memcpy(disk+3,"TESTFAT ",8);le16(11,512);disk[13]=1;le16(14,1);disk[16]=2;
    le16(17,512);le16(19,SECTORS);disk[21]=0xf8;le16(22,64);
    le16(24,32);le16(26,64);disk[38]=0x29;memcpy(disk+54,"FAT16   ",8);le16(510,0xaa55);
    for (unsigned fat=1;fat<=65;fat+=64) {disk[fat*512]=0xf8;memset(disk+fat*512+1,0xff,3);}
}
int main(void)
{
    const struct config_io io={settings_media_read,settings_media_truncate,settings_media_write};
    struct config_store s;
    present=false;assert(!settings_media_present());assert(!settings_media_truncate(0));assert(!writes);
    present=true;assert(!settings_media_present()); /* unformatted rejected */
    format_fixture();assert(settings_media_present());config_load(&s,&io);assert(!s.saved&&s.writable&&!writes);
    FIL other;UINT n;assert(f_open(&other,"0:/KEEP.TXT",FA_WRITE|FA_CREATE_ALWAYS)==FR_OK);
    assert(f_write(&other,"untouched",9,&n)==FR_OK&&n==9);assert(f_close(&other)==FR_OK);
    assert(config_save(&s,&io,&s.value));assert(settings_media_present());config_load(&s,&io);assert(s.saved);
    struct switch_config next=s.value;next.admin=3;assert(config_save(&s,&io,&next));assert(settings_media_present());config_load(&s,&io);assert(s.value.admin==3);
    unsigned old=writes;assert(config_save(&s,&io,&s.value));assert(writes==old);
    fail_write=true;next.admin=7;assert(!config_save(&s,&io,&next));fail_write=false;
    assert(settings_media_present());config_load(&s,&io);assert(s.saved&&s.value.admin==3);
    fail_sync=true;next.admin=15;assert(!config_save(&s,&io,&next));fail_sync=false;
    assert(settings_media_present());config_load(&s,&io);assert(s.saved&&s.value.admin==3);
    assert(!settings_media_write(2,0,"x",1));assert(!settings_media_write(0,256,"x",1));
    char keep[9];assert(f_open(&other,"0:/KEEP.TXT",FA_READ)==FR_OK);
    assert(f_read(&other,keep,9,&n)==FR_OK&&n==9&&!memcmp(keep,"untouched",9));assert(f_close(&other)==FR_OK);
    present=false;assert(!settings_media_present());assert(!settings_media_write(0,0,"x",1));
    present=true;format_fixture();assert(settings_media_present());config_load(&s,&io);assert(!s.saved&&s.writable);
    assert(f_open(&other,"0:/KR260A.CFG",FA_WRITE|FA_CREATE_ALWAYS)==FR_OK);
    unsigned char oversized[257]={0};assert(f_write(&other,oversized,sizeof(oversized),&n)==FR_OK);assert(f_close(&other)==FR_OK);
    config_load(&s,&io);assert(!s.writable);
    puts("PASS: real FAT mount/save/reload, missing/replaced media, write/sync failures and unrelated-file preservation");
}
