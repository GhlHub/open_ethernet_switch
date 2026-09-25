#include "config.h"
#include <string.h>
static const uint8_t magic[8]={'K','R','2','6','0','C','F','G'};
static uint32_t get32(const uint8_t *p)
{ return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24); }
static void put32(uint8_t *p,uint32_t x)
{ for (unsigned i=0;i<4;i++) p[i]=(uint8_t)(x>>(8*i)); }
static uint32_t crc(const uint8_t *p,size_t n)
{
    uint32_t v=UINT32_MAX;
    while (n--) {v^=*p++;for (unsigned b=0;b<8;b++) v=(v>>1)^(0xedb88320u & (0u-(v&1)));}
    return ~v;
}
void config_defaults(struct switch_config *c)
{
    memset(c,0,sizeof(*c));
    for (unsigned i=0;i<CONFIG_MAC_COUNT;i++) {
        const uint8_t m[]={0x00,0x0a,0x35,0x0f,0x37,0x45};
        memcpy(c->mac[i],m,6);c->mac[i][5]+=(uint8_t)i;
    }
    strcpy(c->username,"admin");
    memcpy(c->password_salt,"kr260-0a350f3745",16);
    const uint8_t hash[]={0xbe,0x04,0xc1,0xe4,0xa0,0xfe,0x61,0x73,0x03,0xd2,0x44,0x7f,0x93,0xbe,0x2d,0xc3,0x78,0xf9,0x3b,0x62,0x75,0xf4,0x9a,0x8c,0xa7,0x93,0x61,0x97,0xb9,0xc3,0x56,0xca};
    memcpy(c->password_hash,hash,32);c->password_rounds=CONFIG_PASSWORD_ROUNDS;
    c->admin=31;c->advertise[0]=4;
    for (unsigned i=1;i<4;i++) c->advertise[i]=7;
    c->sfp_speed=0;c->dhcp=true;
}
static uint32_t ip32(const uint8_t p[4])
{ return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
static bool unicast(const uint8_t p[4])
{ return p[0]!=0 && p[0]!=127 && p[0]<224; }
bool config_valid(const struct switch_config *c)
{
    struct switch_config factory; config_defaults(&factory);
    /* This board's allocation is permanent, never writable through settings. */
    if (memcmp(c->mac,factory.mac,sizeof(c->mac)) || c->admin>31 || c->advertise[0]!=4 ||
        c->password_rounds!=CONFIG_PASSWORD_ROUNDS) return false;
    size_t len=0;
    while (len<sizeof(c->username) && c->username[len]) {
        char ch=c->username[len++];
        if (!((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||ch=='_'||ch=='-'||ch=='.')) return false;
    }
    if (!len || len==sizeof(c->username)) return false;
    for (unsigned i=1;i<4;i++) if (!c->advertise[i] || c->advertise[i]>7) return false;
    if (c->sfp_speed && c->sfp_speed!=1000 && c->sfp_speed!=2500 && c->sfp_speed!=5000 && c->sfp_speed!=10000) return false;
    if (!c->dhcp) {
        uint32_t ip=ip32(c->ip), mask=ip32(c->netmask), gw=ip32(c->gateway), host=~mask;
        if (!unicast(c->ip) || !mask || host<3 || (host&(host+1)) ||
            !(ip&host) || (ip&host)==host) return false;
        if (gw && (!unicast(c->gateway) || (gw&mask)!=(ip&mask) ||
            !(gw&host) || (gw&host)==host || gw==ip)) return false;
    }
    return true;
}
bool config_parse_ipv4(const char *s,uint8_t out[4])
{
    uint8_t result[4];
    for (unsigned i=0;i<4;i++) {
        unsigned n=0,digits=0;
        while (*s>='0' && *s<='9') {n=n*10u+(unsigned)(*s++-'0');if (++digits>3 || n>255) return false;}
        if (!digits || (i<3 ? *s++!='.' : *s!=0)) return false;
        result[i]=(uint8_t)n;
    }
    memcpy(out,result,4);return true;
}
void config_encode(const struct switch_config *c,uint32_t sequence,uint8_t out[CONFIG_RECORD_SIZE])
{
    memset(out,0,CONFIG_RECORD_SIZE);memcpy(out,magic,8);put32(out+8,1);put32(out+12,sequence);
    memcpy(out+16,c->mac,30);memcpy(out+46,c->username,32);
    memcpy(out+78,c->password_salt,16);memcpy(out+94,c->password_hash,32);
    put32(out+126,c->password_rounds);out[130]=c->admin;memcpy(out+131,c->advertise,4);
    out[135]=(uint8_t)c->sfp_speed;out[136]=(uint8_t)(c->sfp_speed>>8);out[137]=c->dhcp;
    memcpy(out+138,c->ip,4);memcpy(out+142,c->netmask,4);memcpy(out+146,c->gateway,4);
    put32(out+248,crc(out,248));memcpy(out+252,"DONE",4);
}
bool config_decode(const uint8_t data[CONFIG_RECORD_SIZE],struct switch_config *c,uint32_t *sequence)
{
    if (memcmp(data,magic,8)||get32(data+8)!=1||memcmp(data+252,"DONE",4)||get32(data+248)!=crc(data,248)||data[137]>1) return false;
    struct switch_config v={0};memcpy(v.mac,data+16,30);memcpy(v.username,data+46,32);
    memcpy(v.password_salt,data+78,16);memcpy(v.password_hash,data+94,32);v.password_rounds=get32(data+126);
    v.admin=data[130];memcpy(v.advertise,data+131,4);v.sfp_speed=data[135]|((uint16_t)data[136]<<8);v.dhcp=data[137];
    memcpy(v.ip,data+138,4);memcpy(v.netmask,data+142,4);memcpy(v.gateway,data+146,4);
    if (!config_valid(&v)) return false;
    *c=v;*sequence=get32(data+12);return true;
}
static bool blank(const uint8_t *p,size_t n)
{ while (n--) if (*p++!=255) return false;return true; }
bool config_load(struct config_store *s,const struct config_io *io)
{
    memset(s,0,sizeof(*s));config_defaults(&s->value);s->slot=-1;s->writable=true;
    for (unsigned slot=0;slot<2;slot++) {
        uint8_t record[256];struct switch_config c;uint32_t sequence;
        if (!io->read(slot,0,record,sizeof(record))) {s->writable=false;continue;}
        bool valid=config_decode(record,&c,&sequence);
        if (valid && (s->slot<0 || (int32_t)(sequence-s->sequence)>0)) {
            s->value=c;s->sequence=sequence;s->slot=(int)slot;s->saved=true;
        }
        /* Unknown record versions are never replaced automatically. A torn
         * record with our v1 header can be reclaimed on an explicit save. */
        if (!blank(record,sizeof(record)) && (memcmp(record,magic,8)||get32(record+8)!=1)) s->writable=false;

    }
    return s->saved;
}
bool config_save(struct config_store *s,const struct config_io *io,const struct switch_config *value)
{
    if (!s->writable || !config_valid(value)) return false;
    uint8_t record[256],verify[256];uint32_t seq=s->sequence+1;
    config_encode(value,seq,record);
    if (s->saved) {
        config_encode(&s->value,seq,verify);
        if (!memcmp(record,verify,sizeof(record))) return true; /* unchanged record */
    }
    unsigned slot=s->slot==0?1:0;
    if (!io->truncate(slot) || !io->write(slot,0,record,252) ||
        !io->read(slot,0,verify,252) || memcmp(record,verify,252) ||
        !io->write(slot,252,record+252,4) || !io->read(slot,0,verify,256) ||
        memcmp(record,verify,256)) return false;
    s->value=*value;s->sequence=seq;s->slot=(int)slot;s->saved=true;return true;
}
