#include "config.h"
#include "config_web.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static uint8_t files[2][CONFIG_SLOT_SIZE],backup[2][CONFIG_SLOT_SIZE];
static int budget=-1,truncates;
static bool read_file(unsigned s,unsigned off,void *p,size_t n)
{ assert(s<2 && off+n<=CONFIG_SLOT_SIZE);memcpy(p,files[s]+off,n);return true; }
static bool truncate_file(unsigned s)
{ assert(s<2);memset(files[s],255,CONFIG_SLOT_SIZE);truncates++;return true; }
static bool write_file(unsigned s,unsigned off,const void *p,size_t n)
{
    assert(s<2 && off+n<=256);const uint8_t *v=p;
    for (size_t i=0;i<n;i++) {if (budget==0) return false;if (budget>0) budget--;files[s][off+i]=v[i];}
    return true;
}
static const struct config_io io={read_file,truncate_file,write_file};
static bool form(const char *text)
{ char buf[512];assert(strlen(text)<sizeof(buf));strcpy(buf,text);struct switch_config c;bool credentials;return config_form(buf,&c,&credentials); }
int main(void)
{
    struct config_store s,t;struct switch_config c,decoded;uint32_t sequence;
    memset(files,255,sizeof(files));assert(!config_load(&s,&io) && s.writable && !s.saved);
    c=s.value;assert(config_valid(&c));
    for (unsigned i=0;i<5;i++) {assert(c.mac[i][0]==0 && c.mac[i][1]==10 && c.mac[i][5]==0x45+i);}
    uint8_t record[256];config_encode(&c,UINT32_MAX,record);assert(config_decode(record,&decoded,&sequence));
    assert(sequence==UINT32_MAX && !memcmp(c.mac,decoded.mac,30));
    for (unsigned i=0;i<256;i++) {record[i]^=1;assert(!config_decode(record,&decoded,&sequence));record[i]^=1;}
    assert(config_save(&s,&io,&c));assert(config_load(&t,&io)&&t.saved&&t.writable);
    int before=truncates;assert(config_save(&s,&io,&c)&&truncates==before);
    memcpy(backup,files,sizeof(files));
    c.admin=29;
    for (int cut=0;cut<256;cut++) {
        memcpy(files,backup,sizeof(files));assert(config_load(&s,&io));budget=cut;
        assert(!config_save(&s,&io,&c));assert(s.value.admin==31);
        assert(config_load(&t,&io)&&t.value.admin==31);
    }
    budget=-1;memcpy(files,backup,sizeof(files));assert(config_load(&s,&io));
    assert(config_save(&s,&io,&c));assert(config_load(&t,&io)&&t.value.admin==29);
    files[t.slot][94]^=1;assert(config_load(&t,&io)&&t.value.admin==31);
    memset(files,255,sizeof(files));memcpy(files[0],"FOREIGN",7);assert(!config_load(&s,&io)&&!s.writable);
    memset(files,255,sizeof(files));config_encode(&c,UINT32_MAX,files[0]);c.admin=30;config_encode(&c,0,files[1]);
    assert(config_load(&s,&io)&&s.value.admin==30);
    config_defaults(&c);c.mac[1][5]++;assert(!config_valid(&c));config_defaults(&c);
    c.advertise[0]=7;assert(!config_valid(&c));config_defaults(&c);
    for(unsigned i=1;i<4;i++) for(unsigned mask=1;mask<=7;mask++){c.advertise[i]=(uint8_t)mask;assert(config_valid(&c));}
    const uint16_t speeds[]={0,1000,2500,5000,10000};for(unsigned i=0;i<5;i++){c.sfp_speed=speeds[i];assert(config_valid(&c));}
    c.sfp_speed=100;assert(!config_valid(&c));c.sfp_speed=0;
    c.dhcp=false;assert(!config_valid(&c));
    assert(config_parse_ipv4("10.0.1.214",c.ip));assert(config_parse_ipv4("255.255.255.0",c.netmask));
    assert(config_parse_ipv4("10.0.1.1",c.gateway));assert(config_valid(&c));
    c.netmask[2]=253;assert(!config_valid(&c));c.netmask[2]=255;
    c.gateway[2]=2;assert(!config_valid(&c));c.gateway[2]=1;
    c.ip[3]=255;assert(!config_valid(&c));c.ip[3]=214;
    const char *bad[]={"1.2.3","1.2.3.256","1.2.3.4x","-1.2.3.4","1..2.3","1.2.3.4.5","999999999999999999.0.0.1"};
    for(unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);i++)assert(!config_parse_ipv4(bad[i],c.ip));
    const char *good="mask=31&adv0=4&adv1=7&adv2=7&adv3=7&sfp=0&dhcp=1&ip=0.0.0.0&netmask=0.0.0.0&gateway=0.0.0.0";
    assert(form(good));char text[512];snprintf(text,sizeof(text),"%s&mask=31",good);assert(!form(text));
    snprintf(text,sizeof(text),"%s&username=admin",good);assert(!form(text));
    assert(!form("mask=31"));
    char json[1024];assert(config_json(json,sizeof(json),&c,true,true));assert(!strstr(json,"password")&&!strstr(json,"salt")&&!strstr(json,"hash"));
    assert(!config_json(json,10,&c,true,true));
    puts("PASS: defaults, all-byte CRC corruption, interrupted saves, redundant recovery, foreign-region protection, sequence wrap, port/IP validation and public JSON");
}
