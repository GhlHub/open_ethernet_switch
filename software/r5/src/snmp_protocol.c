/* Small read-only SNMPv2c BER engine. No allocation, network or MMIO access.
 * Bounds are intentional: 1400-byte datagrams, 32 request varbinds, 24 arcs,
 * 64 response varbinds. GETBULK is truncated at the response/work limit. */
#include "snmp.h"
#include <stdbool.h>
#include <string.h>
#include <limits.h>
#define REQUEST_MAX 32
#define RESPONSE_MAX 64
struct reader { const uint8_t *p; size_t n; };
struct writer { uint8_t *p; size_t n,cap; bool ok; };
static bool tlv(struct reader *r,uint8_t *tag,struct reader *v)
{
    if (r->n<2) return false;
    *tag=*r->p++; r->n--;
    size_t n=*r->p++; r->n--;
    if (n&128) {
        unsigned bytes=(unsigned)n&127;
        if (!bytes || bytes>4 || bytes>r->n) return false;
        n=0;
        while (bytes--) { n=(n<<8)|*r->p++; r->n--; }
    }
    if (n>r->n) return false;
    *v=(struct reader){r->p,n}; r->p+=n; r->n-=n;
    return true;
}
static bool expect(struct reader *r,uint8_t tag,struct reader *v)
{
    uint8_t got;
    return tlv(r,&got,v) && got==tag;
}
static bool integer(struct reader *r,int32_t *out)
{
    struct reader v;
    if (!expect(r,2,&v) || !v.n) return false;
    while (v.n>1 && ((v.p[0]==0 && !(v.p[1]&128)) ||
                    (v.p[0]==255 && (v.p[1]&128)))) { v.p++; v.n--; }
    if (v.n>4) return false;
    int64_t x=(v.p[0]&128)?-1:0;
    while (v.n--) x=x*256+*v.p++;
    *out=(int32_t)x; return true;
}
static bool oid_read(struct reader v,struct snmp_oid *o)
{
    o->length=0;
    if (!v.n) return false;
    while (v.n) {
        uint64_t x=0; unsigned count=0; uint8_t b;
        do {
            if (!v.n || ++count>5) return false;
            b=*v.p++; v.n--;
            if (count==1 && b==128) return false;
            x=(x<<7)|(b&127);
        } while (b&128);
        if (!o->length) {
            unsigned first=x<40?0:x<80?1:2;
            if (x-first*40u>UINT32_MAX) return false;
            o->arc[o->length++]=first;
            o->arc[o->length++]=(uint32_t)(x-first*40u);
        } else {
            if (x>UINT32_MAX || o->length==SNMP_OID_MAX) return false;
            o->arc[o->length++]=(uint32_t)x;
        }
    }
    return true;
}
static void put(struct writer *w,const void *p,size_t n)
{
    if (!w->ok || n>w->cap-w->n) { w->ok=false; return; }
    if (n) memcpy(w->p+w->n,p,n);
    w->n+=n;
}
static void byte(struct writer *w,uint8_t b) { put(w,&b,1); }
static size_t begin(struct writer *w,uint8_t tag)
{
    size_t start=w->n;
    byte(w,tag); byte(w,0x82); byte(w,0); byte(w,0);
    return start;
}
static void end(struct writer *w,size_t start)
{
    if (!w->ok) return;
    size_t len=w->n-start-4, header=len<128?2:len<256?3:4;
    memmove(w->p+start+header,w->p+start+4,len);
    w->n-=4-header;
    if (header==2) w->p[start+1]=(uint8_t)len;
    else if (header==3) { w->p[start+1]=0x81; w->p[start+2]=(uint8_t)len; }
    else { w->p[start+2]=(uint8_t)(len>>8); w->p[start+3]=(uint8_t)len; }
}
static void number(struct writer *w,uint8_t type,uint64_t value)
{
    uint8_t b[9]; size_t first=1;
    for (unsigned i=0;i<8;i++) b[i+1]=(uint8_t)(value>>(56-8*i));
    if (type==2) {
        while (first<8 && ((b[first]==0 && !(b[first+1]&128)) ||
                          (b[first]==255 && (b[first+1]&128)))) first++;
    } else {
        while (first<8 && b[first]==0) first++;
        if (b[first]&128) b[--first]=0;
    }
    byte(w,type); byte(w,(uint8_t)(9-first)); put(w,b+first,9-first);
}
static void subid(struct writer *w,uint64_t x)
{
    uint8_t b[5]; unsigned n=0;
    do { b[n++]=(uint8_t)(x&127); x>>=7; } while (x);
    while (n) { n--; byte(w,b[n]|(n?128:0)); }
}
static void oid_write(struct writer *w,const struct snmp_oid *o)
{
    size_t start=begin(w,6);
    subid(w,(uint64_t)o->arc[0]*40+o->arc[1]);
    for (size_t i=2;i<o->length;i++) subid(w,o->arc[i]);
    end(w,start);
}
static int compare(const struct snmp_oid *a,const struct snmp_oid *b)
{
    size_t n=a->length<b->length?a->length:b->length;
    for (size_t i=0;i<n;i++) if (a->arc[i]!=b->arc[i])
        return a->arc[i]<b->arc[i]?-1:1;
    return a->length==b->length?0:a->length<b->length?-1:1;
}
static const struct snmp_object *lookup(const struct snmp_mib *m,
                                       const struct snmp_oid *o,bool next)
{
    for (size_t i=0;i<m->count;i++) {
        int cmp=compare(&m->object[i].oid,o);
        if ((!next && cmp==0) || (next && cmp>0)) return &m->object[i];
    }
    return NULL;
}
static uint8_t missing(const struct snmp_mib *m,const struct snmp_oid *o)
{
    for (size_t i=0;i<m->count;i++) {
        const struct snmp_oid *p=&m->object[i].oid;
        size_t base=p->length-m->object[i].instance_arcs;
        if (o->length>=base && !memcmp(p->arc,o->arc,base*sizeof(uint32_t)))
            return 0x81; /* known object, absent instance */
    }
    return 0x80;
}
static void binding(struct writer *w,const struct snmp_oid *o,
                     const struct snmp_object *v,uint8_t exception)
{
    size_t start=begin(w,0x30);
    oid_write(w,o);
    if (!v) { byte(w,exception); byte(w,0); }
    else if (v->type==4) {
        size_t pos=begin(w,4); put(w,v->text,strlen(v->text)); end(w,pos);
    } else if (v->type==6) {
        const struct snmp_oid root={{1,3,6,1,4,1,SNMP_ENTERPRISE,1},8};
        oid_write(w,&root);
    } else number(w,v->type,v->number);
    end(w,start);
}
static size_t response(uint8_t *out,size_t cap,const char *community,
                        int32_t id,unsigned error,unsigned index,
                        const uint8_t *list,size_t length)
{
    struct writer w={out,0,cap,true};
    size_t msg=begin(&w,0x30);
    number(&w,2,1);
    size_t com=begin(&w,4); put(&w,community,strlen(community)); end(&w,com);
    size_t pdu=begin(&w,0xa2);
    number(&w,2,(uint64_t)(int64_t)id); number(&w,2,error); number(&w,2,index);
    size_t vars=begin(&w,0x30); put(&w,list,length); end(&w,vars);
    end(&w,pdu); end(&w,msg);
    return w.ok?w.n:0;
}
size_t snmp_respond(const uint8_t *in,size_t length,uint8_t *out,size_t cap,
                    const char *community,const struct snmp_mib *m)
{
    struct reader r={in,length},msg,com,pdu,list,vb,v;
    int32_t version,id,first,second; uint8_t operation,type;
    struct snmp_oid oid[REQUEST_MAX]; unsigned count=0;
    size_t comlen=strlen(community);
    if (length>SNMP_PACKET_MAX || cap<128 || comlen>64 || !comlen ||
        !expect(&r,0x30,&msg) || r.n || !integer(&msg,&version) || version!=1 ||
        !expect(&msg,4,&com) || com.n!=comlen || memcmp(com.p,community,comlen) ||
        !tlv(&msg,&operation,&pdu) || msg.n ||
        (operation!=0xa0 && operation!=0xa1 && operation!=0xa3 && operation!=0xa5) ||
        !integer(&pdu,&id) || !integer(&pdu,&first) || !integer(&pdu,&second) ||
        !expect(&pdu,0x30,&list) || pdu.n) return 0;
    struct reader original=list;
    while (list.n) {
        if (count==REQUEST_MAX || !expect(&list,0x30,&vb) ||
            !expect(&vb,6,&v) || !oid_read(v,&oid[count++]) ||
            !tlv(&vb,&type,&v) || vb.n) return 0;
        /* Values in retrieval requests are ignored, as specified by RFC 3416. */
    }
    if (operation==0xa3) {
        /* Echo original bindings; no setter or MMIO access exists. */
        size_t n=response(out,cap,community,id,count?17:0,count?1:0,original.p,original.n);
        return n?n:response(out,cap,community,id,1,0,NULL,0);
    }
    uint8_t body[SNMP_PACKET_MAX];
    /* Reserve a conservative message envelope including max community. */
    size_t limit=cap>SNMP_PACKET_MAX?SNMP_PACKET_MAX:cap;
    struct writer w={body,0,limit-112,true};
    unsigned nonrepeat=count, repeats=0, emitted=0;
    if (operation==0xa5) {
        nonrepeat=first<0?0:(uint32_t)first>count?count:(unsigned)first;
        repeats=second<0?0:(unsigned)second;
        if (repeats>RESPONSE_MAX) repeats=RESPONSE_MAX;
    }
    for (unsigned round=0;round<=repeats;round++) {
        unsigned start=round?nonrepeat:0,stop=round?count:nonrepeat;
        bool all_end=true;
        for (unsigned i=start;i<stop;i++) {
            bool next=operation!=0xa0;
            const struct snmp_object *obj=lookup(m,&oid[i],next);
            if (obj) { oid[i]=obj->oid; all_end=false; }
            size_t before=w.n;
            binding(&w,&oid[i],obj,next?0x82:missing(m,&oid[i]));
            if (!w.ok || emitted==RESPONSE_MAX) {
                if (operation!=0xa5) return response(out,cap,community,id,1,0,NULL,0);
                w.n=before; goto done;
            }
            emitted++;
        }
        if (round && all_end) break;
    }
done:
    return response(out,cap,community,id,0,0,body,w.n);
}
