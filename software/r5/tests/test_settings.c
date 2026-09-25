#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../src/settings.c"
static uint8_t files[2][CONFIG_RECORD_SIZE];
static bool present,write_fail;
static unsigned writes;
static uint8_t admitted;
int xil_printf(const char *fmt,...){(void)fmt;return 0;}
bool board_ports_configure(uint8_t mask,const uint8_t adv[2]){assert(adv[0]==4);admitted=mask;return true;}
bool settings_media_present(void){return present;}
const char *settings_media_status(void){return "no card";}
bool settings_media_read(unsigned slot,unsigned offset,void *data,size_t size)
{assert(slot<2&&offset+size<=256);if(!present)return false;memcpy(data,files[slot]+offset,size);return true;}
bool settings_media_truncate(unsigned slot)
{assert(slot<2);if(!present||write_fail)return false;memset(files[slot],255,256);writes++;return true;}
bool settings_media_write(unsigned slot,unsigned offset,const void *data,size_t size)
{assert(slot<2&&offset+size<=256);if(!present||write_fail)return false;memcpy(files[slot]+offset,data,size);writes++;return true;}
int main(void)
{
    memset(files,255,sizeof(files));struct switch_config c;bool saved,writable;
    settings_init();settings_get(&c,&saved,&writable);assert(!saved&&!writable&&admitted==31&&writes==0);
    assert(!settings_save(&c));present=true;settings_init();settings_get(&c,&saved,&writable);
    assert(!saved&&writable&&c.dhcp&&!strcmp(c.username,"admin"));
    c.advertise[2]=3;c.sfp_speed=2500;assert(settings_save(&c));assert(admitted==11);
    settings_init();settings_get(&c,&saved,&writable);
#if CONFIG_RECOVERY
    assert(!saved&&writable&&c.sfp_speed==0&&admitted==31);
    assert(writes==3);assert(settings_save(&c));
    puts("PASS: recovery uses defaults without writing until explicit save");return 0;
#else
    assert(saved&&writable&&c.sfp_speed==2500&&admitted==11);
    assert(settings_save(&c)&&writes==3);
    present=false;settings_get(&c,&saved,&writable);assert(!writable);
    assert(!settings_save(&c)&&writes==3); /* even unchanged save needs a card */
    settings_init();settings_get(&c,&saved,&writable);assert(!saved&&!writable&&c.sfp_speed==0&&c.dhcp);
    present=true;settings_init();settings_get(&c,&saved,&writable);assert(saved&&writable);
    write_fail=true;c.admin=1;assert(!settings_save(&c));settings_get(&c,&saved,&writable);assert(c.admin==31);
    write_fail=false;memset(files,255,sizeof(files)); /* replacement empty card */
    assert(settings_save(&c)&&writes==6);
    puts("PASS: absent/missing-config defaults, save/reload, removal rejects no-op save, failed save preserves runtime, replacement-card ownership and unsupported ports");
#endif
}
