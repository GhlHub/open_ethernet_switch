#include "web.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static void check(const char *s,int result) { struct web_request r; assert(web_parse(s,strlen(s),&r)==result); }
int main(void)
{
    const char *post="POST /api/ports HTTP/1.1\r\nContent-Length: 7\r\nX-KR260-Request: 1\r\n\r\nmask=30";
    struct web_request r;
    for (size_t n=0;n<strlen(post);n++) assert(web_parse(post,n,&r)==0);
    assert(web_parse(post,strlen(post),&r)==1 && r.mask==30);
    check("GET /api/statistics HTTP/1.1\r\nHost: board\r\n\r\n",1);
    check("GET / HTTP/1.0\r\n\r\n",1);
    check("POST /api/ports HTTP/1.1\r\nContent-Length: 7\r\n\r\nmask=30",-1);
    check("POST /api/ports HTTP/1.1\r\nContent-Length: 7\r\nX-KR260-Request: 1\r\n\r\nmask=32",-1);
    check("POST /api/ports HTTP/1.1\r\nContent-Length: 7\r\nX-KR260-Request: 1\r\n\r\nmask=-1",-1);
    check("POST /api/ports HTTP/1.1\r\nContent-Length: 7\r\nContent-Length: 7\r\n\r\nmask=30",-1);
    check("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",-1);
    check("GET / HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n",-1);
    struct statistics_snapshot s={.available=true}; struct sensor_snapshot v={0};
    s.port[0][0]=UINT64_MAX;
    for(unsigned b=0;b<13;b++)for(unsigned i=0;i<16;i++){
        s.release_timeout_by_index[b][i]=UINT32_MAX;s.response_timeout_by_index[b][i]=UINT32_MAX;
    }
    char output[24576];
    assert(web_stats(output,10,&s,&v,100,200)==0);
    assert(web_stats(output,sizeof(output),&s,&v,100,200)>0);
    assert(strstr(output,"\"18446744073709551615\""));
    puts(output);
    return 0;
}
