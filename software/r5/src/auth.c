#include "auth.h"
#include "sha256.h"
#include <string.h>
static void wipe(void *p,size_t size)
{ volatile uint8_t *q=p;while (size--) *q++=0; }
static void hmac(const SHA256_CTX *inner,const SHA256_CTX *outer,const uint8_t *data,size_t n,uint8_t out[32])
{
    uint8_t digest[32];SHA256_CTX c=*inner;
    sha256_update(&c,data,n);sha256_final(&c,digest);c=*outer;
    sha256_update(&c,digest,32);sha256_final(&c,out);wipe(&c,sizeof(c));wipe(digest,sizeof(digest));
}
void auth_derive(const uint8_t *password,size_t size,const uint8_t salt[16],uint32_t rounds,uint8_t hash[32])
{
    uint8_t key[64]={0},pad[64],u[32],first[20];SHA256_CTX inner,outer;
    if (size>64) {sha256_init(&inner);sha256_update(&inner,password,size);sha256_final(&inner,key);}
    else memcpy(key,password,size);
    for (unsigned i=0;i<64;i++) pad[i]=key[i]^0x36;
    sha256_init(&inner);sha256_update(&inner,pad,64);
    for (unsigned i=0;i<64;i++) pad[i]=key[i]^0x5c;
    sha256_init(&outer);sha256_update(&outer,pad,64);
    memcpy(first,salt,16);memset(first+16,0,3);first[19]=1;
    hmac(&inner,&outer,first,sizeof(first),u);memcpy(hash,u,32);
    for(uint32_t i=1;i<rounds;i++){hmac(&inner,&outer,u,32,u);for(unsigned j=0;j<32;j++)hash[j]^=u[j];}
    wipe(key,sizeof(key));wipe(pad,sizeof(pad));wipe(u,sizeof(u));wipe(first,sizeof(first));
    wipe(&inner,sizeof(inner));wipe(&outer,sizeof(outer));
}
static int digit(char c)
{
    if(c>='A'&&c<='Z')return c-'A';
    if(c>='a'&&c<='z')return c-'a'+26;
    if(c>='0'&&c<='9')return c-'0'+52;
    if(c=='+')return 62;
    if(c=='/')return 63;
    return -1;
}
static bool decode(const char *in,uint8_t *out,size_t *size)
{
    size_t n=strlen(in),used=0;if(!n||n%4||n>216)return false;
    for(size_t i=0;i<n;i+=4){
        int a=digit(in[i]),b=digit(in[i+1]),c=digit(in[i+2]),d=digit(in[i+3]);
        bool p2=in[i+2]=='=',p3=in[i+3]=='=';
        if(a<0||b<0||(!p2&&c<0)||(!p3&&d<0)||(p2&&!p3)||((p2||p3)&&i+4!=n))return false;
        if((p2&&(b&15))||(!p2&&p3&&(c&3)))return false;
        out[used++]=(uint8_t)((a<<2)|(b>>4));
        if(!p2)out[used++]=(uint8_t)((b<<4)|(c>>2));
        if(!p3)out[used++]=(uint8_t)((c<<6)|d);
    }
    *size=used;return true;
}
bool auth_verify(const struct switch_config *cfg,const char *header)
{
    uint8_t decoded[162]={0},hash[32];size_t n=0;bool ok=false;
    if (strncmp(header,"Basic ",6) || cfg->password_rounds!=CONFIG_PASSWORD_ROUNDS) return false;
    if(!decode(header+6,decoded,&n)||memchr(decoded,0,n))goto done;
    uint8_t *colon=memchr(decoded,':',n);if(!colon)goto done;
    size_t user=(size_t)(colon-decoded),pass=n-user-1;
    if(!user||user>=sizeof(cfg->username)||!pass||pass>128||strlen(cfg->username)!=user||memcmp(cfg->username,decoded,user))goto done;
    auth_derive(colon+1,pass,cfg->password_salt,cfg->password_rounds,hash);
    unsigned difference=0;for(unsigned i=0;i<32;i++)difference|=hash[i]^cfg->password_hash[i];ok=difference==0;
 done:
    wipe(decoded,sizeof(decoded));wipe(hash,sizeof(hash));return ok;
}
