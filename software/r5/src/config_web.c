#include "config_web.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static bool hex(const char *s,uint8_t *out,size_t size)
{
    if (strlen(s)!=2*size) return false;
    for (size_t i=0;i<size;i++) {
        unsigned v=0;
        for (unsigned j=0;j<2;j++) {
            char c=*s++;unsigned n;
            if (c>='0'&&c<='9') n=(unsigned)(c-'0');
            else if (c>='a'&&c<='f') n=(unsigned)(c-'a')+10;
            else if (c>='A'&&c<='F') n=(unsigned)(c-'A')+10;
            else return false;
            v=v*16+n;
        }
        out[i]=(uint8_t)v;
    }
    return true;
}
bool config_form(char *body,struct switch_config *out,bool *credentials)
{
    static const char *keys[]={"mask","adv0","adv1","adv2","adv3","sfp","dhcp","ip","netmask","gateway","username","salt","hash"};
    struct switch_config c;config_defaults(&c);unsigned seen=0;
    for (char *p=body;*p;) {
        char *next=strchr(p,'&');if (next) {*next++=0;if (!*next) return false;}
        char *v=strchr(p,'=');if (!v) return false;*v++=0;
        unsigned k;for (k=0;k<13;k++) if (!strcmp(p,keys[k])) break;
        if (k==13 || (seen&(1u<<k))) return false;
        seen|=1u<<k;
        if (k<=6) {
            if (*v<'0'||*v>'9') return false;
            /* Bounded decimal conversion, including overflow rejection. */
            unsigned n=0;for (const char *q=v;*q;q++) {
                if (*q<'0'||*q>'9'||n>10000) return false;
                n=n*10+(unsigned)(*q-'0');
            }
            if (k==0) {if (n>31) return false;c.admin=(uint8_t)n;}
            else if (k<=4) {if (!n||n>7) return false;c.advertise[k-1]=(uint8_t)n;}
            else if (k==5) {if (n>10000) return false;c.sfp_speed=(uint16_t)n;}
            else {if (n>1) return false;c.dhcp=n!=0;}
        } else if (k<=9) {
            if (!config_parse_ipv4(v,k==7?c.ip:k==8?c.netmask:c.gateway)) return false;
        } else if (k==10) {
            if (strlen(v)>=sizeof(c.username)) return false;
            strcpy(c.username,v);
        } else if (!hex(v,k==11?c.password_salt:c.password_hash,k==11?16:32)) return false;
        p=next?next:v+strlen(v);
    }
    if (seen!=0x3ffu && seen!=0x1fffu) return false;
    if (!config_valid(&c)) return false;
    *out=c;*credentials=seen==0x1fff;return true;
}
size_t config_json(char *out,size_t size,const struct switch_config *c,bool saved,bool writable)
{
    char macs[128];size_t used=0;
    for (unsigned i=0;i<5;i++) {
        int n=snprintf(macs+used,sizeof(macs)-used,"%s\"%02x:%02x:%02x:%02x:%02x:%02x\"",i?",":"",
            c->mac[i][0],c->mac[i][1],c->mac[i][2],c->mac[i][3],c->mac[i][4],c->mac[i][5]);
        if (n<0 || (size_t)n>=sizeof(macs)-used) return 0;
        used+=(size_t)n;
    }
    /* Username has a restricted alphabet; verifier and salt are never returned. */
    int n=snprintf(out,size,"{\"saved\":%s,\"writable\":%s,\"macs\":[%s],\"username\":\"%s\",\"admin\":%u,\"advertise\":[%u,%u,%u,%u],\"sfp\":%u,\"dhcp\":%s,\"ip\":\"%u.%u.%u.%u\",\"netmask\":\"%u.%u.%u.%u\",\"gateway\":\"%u.%u.%u.%u\",\"requires_restart_for_ip\":true,\"copper_supported\":[4,7,4,4],\"sfp_supported\":[0,1000]}",
        saved?"true":"false",writable?"true":"false",macs,c->username,c->admin,
        c->advertise[0],c->advertise[1],c->advertise[2],c->advertise[3],c->sfp_speed,c->dhcp?"true":"false",
        c->ip[0],c->ip[1],c->ip[2],c->ip[3],c->netmask[0],c->netmask[1],c->netmask[2],c->netmask[3],c->gateway[0],c->gateway[1],c->gateway[2],c->gateway[3]);
    return n>0 && (size_t)n<size?(size_t)n:0;
}
