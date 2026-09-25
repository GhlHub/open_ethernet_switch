#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
unsigned char __usb_nocache_start[0x100000] __attribute__((aligned(0x100000)));
__asm__(".global __usb_nocache_end\n.set __usb_nocache_end,__usb_nocache_start+0x100000");
void *usb_memalign(size_t,size_t);void usb_free(void *);void *usb_calloc(size_t,size_t);int usb_dma_coherent(const void *);
int main(void)
{
    void *p[100];
    for (unsigned round=0;round<20;round++) {
        for (unsigned i=0;i<100;i++) {size_t align=1u<<(3+i%14);p[i]=usb_memalign(align,128+i*3);assert(p[i] && !((uintptr_t)p[i]&(align-1)) && usb_dma_coherent(p[i]));memset(p[i],i,128+i*3);}
        for (unsigned i=0;i<100;i++) for (unsigned j=0;j<128+i*3;j++) assert(((unsigned char *)p[i])[j]==i);
        for (unsigned i=0;i<100;i+=2) usb_free(p[i]);
        for (unsigned i=1;i<100;i+=2) usb_free(p[i]);
    }
    assert(!usb_memalign(3,100));assert(!usb_memalign((size_t)1<<(sizeof(size_t)*8-1),100));assert(!usb_memalign(64,0x100000));assert(!usb_calloc(SIZE_MAX,2));
    void *large=usb_calloc(1,900000);assert(large);for (unsigned i=0;i<900000;i++) assert(!((unsigned char *)large)[i]);usb_free(large);
    assert(!usb_dma_coherent(&p));puts("PASS: USB DMA allocator alignment, isolation, exhaustion and coalescing");
}
