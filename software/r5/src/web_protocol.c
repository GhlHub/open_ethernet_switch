#include "web.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <ctype.h>
/* No chunking, pipelining, or persistent connections; strict framing. */
int web_parse(const char *data,size_t length,struct web_request *out)
{
    char buf[2048];
    if (length>=sizeof(buf) || memchr(data,0,length)) return -1;
    memcpy(buf,data,length); buf[length]=0;
    char *end=strstr(buf,"\r\n\r\n");
    if (!end) return 0;
    size_t header=(size_t)(end-buf)+4;
    char *line=strstr(buf,"\r\n"); *line=0;
    char version[16], extra; struct web_request r={0};
    if (sscanf(buf,"%7s %63s %15s %c",r.method,r.path,version,&extra)!=3 ||
        (strcmp(version,"HTTP/1.1") && strcmp(version,"HTTP/1.0"))) return -1;
    unsigned body=0; int seen=0, marker=0;
    for (char *p=line+2;p<end;) {
        char *next=strstr(p,"\r\n"); if (!next) return -1; *next=0;
        char *colon=strchr(p,':'); if (!colon) return -1;
        *colon=0; for (char *q=p;*q;q++) *q=(char)tolower((unsigned char)*q);
        char *value=colon+1; while (*value==' ' || *value=='\t') value++;
        if (!strcmp(p,"transfer-encoding")) return -1;
        if (!strcmp(p,"content-length")) {
            if (seen++ || !isdigit((unsigned char)*value)) return -1;
            char *tail; unsigned long n=strtoul(value,&tail,10);
            if (*tail || n>32) return -1;
            body=(unsigned)n;
        }
        if (!strcmp(p,"x-kr260-request") && !strcmp(value,"1")) marker=1;
        p=next+2;
    }
    if (length<header+body) return 0;
    if (length!=header+body) return -1;
    if (!strcmp(r.method,"POST")) {
        if (!marker || !seen || body<6 || strncmp(buf+header,"mask=",5)) return -1;
        char *tail; const char *v=buf+header+5;
        if (!isdigit((unsigned char)*v)) return -1;
        unsigned long mask=strtoul(v,&tail,10);
        if (*tail || mask>31) return -1;
        r.mask=(unsigned)mask;
    } else if (body) return -1;
    *out=r; return 1;
}
struct writer { char *p; size_t size, used; int failed; };
static void put(struct writer *w,const char *fmt,...)
{
    if (w->failed) return;
    va_list ap; va_start(ap,fmt);
    int n=vsnprintf(w->p+w->used,w->size-w->used,fmt,ap); va_end(ap);
    if (n<0 || (size_t)n>=w->size-w->used) w->failed=1;
    else w->used+=(size_t)n;
}
static void values(struct writer *w,const uint64_t *v,unsigned rows,unsigned cols)
{
    put(w,"[");
    for (unsigned r=0;r<rows;r++) {
        put(w,"%s[",r?",":"");
        for (unsigned c=0;c<cols;c++) put(w,"%s\"%llu\"",c?",":"",(unsigned long long)v[r*cols+c]);
        put(w,"]");
    }
    put(w,"]");
}
size_t web_stats(char *out,size_t size,const struct statistics_snapshot *s,
                 const struct sensor_snapshot *v,uint32_t hz,uint64_t now)
{
    struct writer w={out,size,0,0};
    put(&w,"{\"available\":%s,\"capabilities\":%u,\"polls\":%u,\"late_polls\":%u,\"saturated_reads\":%u,\"read_timeouts\":%u,\"release_timeouts\":%u,\"response_timeouts\":%u,\"last_release_index\":%u,\"last_release_target_index\":%u,\"last_response_index\":%u,\"age_ms\":%llu,\"ports\":",
        s->available?"true":"false",s->capabilities,s->polls,s->late_polls,s->saturated_reads,s->read_timeouts,s->mailbox_release_timeouts,s->snapshot_response_timeouts,s->last_release_index,s->last_release_target_index,s->last_response_index,
        (unsigned long long)((hz && s->timestamp && now>=s->timestamp)?(now-s->timestamp)*1000/hz:UINT32_MAX));
    values(&w,&s->port[0][0],6,8);
#if STATS_DDR
    put(&w,",\"ddr\":"); values(&w,&s->ddr[0][0],4,8);
#endif
#if STATS_DEBUG
    put(&w,",\"debug\":"); values(&w,s->debug,1,16);
#endif
    put(&w,",\"timeouts\":["); unsigned n=0;
    for (unsigned b=0;b<13;b++) for (unsigned i=0;i<16;i++)
        if (s->release_timeout_by_index[b][i] || s->response_timeout_by_index[b][i])
            put(&w,"%s[%u,%u,%u,%u]",n++?",":"",b,i,s->release_timeout_by_index[b][i],s->response_timeout_by_index[b][i]);
    put(&w,"],\"sensors\":{\"valid_mask\":%u,\"errors\":%u,\"age_ms\":%llu,\"temperature_mc\":[%ld,%ld],\"voltage_uv\":[%u,%u,%u,%u,%u,%u],\"som_current_ua\":%ld,\"som_voltage_uv\":%u,\"som_power_uw\":%u}}",
        v->valid_mask,v->errors,(unsigned long long)((hz && v->timestamp && now>=v->timestamp)?(now-v->timestamp)*1000/hz:UINT32_MAX),
        (long)v->temperature_mc[0],(long)v->temperature_mc[1],v->voltage_uv[0][0],v->voltage_uv[0][1],v->voltage_uv[0][2],v->voltage_uv[1][0],v->voltage_uv[1][1],v->voltage_uv[1][2],(long)v->som_current_ua,v->som_voltage_uv,v->som_power_uw);
    return w.failed?0:w.used;
}
