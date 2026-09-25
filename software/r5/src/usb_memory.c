/* Dedicated, single-owner USB DMA allocator; aligned, freeing/coalescing. */
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
extern uint8_t __usb_nocache_start[], __usb_nocache_end[];
struct block { size_t size; struct block *next; bool used; };
static struct block *head;
void *usb_memalign(size_t align,size_t size)
{
    if (!size || !align || align>0x100000 || (align&(align-1)) || size>0x100000) return NULL;
    if (align<sizeof(void *)) align=sizeof(void *);
    if (!head) {
        head=(void *)__usb_nocache_start;
        *head=(struct block){(size_t)(__usb_nocache_end-__usb_nocache_start),NULL,false};
    }
    for (struct block *b=head;b;b=b->next) {
        uintptr_t p=((uintptr_t)(b+1)+sizeof(b)+align-1)&~(uintptr_t)(align-1);
        size_t need=(p-(uintptr_t)b+size+sizeof(void *)-1)&~(sizeof(void *)-1);
        if (b->used || need>b->size) continue;
        if (b->size-need>=sizeof(*b)+64) {
            struct block *tail=(void *)((uintptr_t)b+need);
            *tail=(struct block){b->size-need,b->next,false};
            b->next=tail;b->size=need;
        }
        b->used=true; ((struct block **)p)[-1]=b;
        return (void *)p;
    }
    return NULL;
}
void *usb_malloc(size_t size) {return usb_memalign(8,size);}
void *usb_calloc(size_t count,size_t size)
{
    if (size && count>SIZE_MAX/size) return NULL;
    void *p=usb_malloc(count*size);if (p) memset(p,0,count*size);return p;
}
void usb_free(void *p)
{
    if (!p) return;
    struct block *b=((struct block **)p)[-1]; b->used=false;
    for (b=head;b && b->next;) {
        if (!b->used && !b->next->used) {b->size+=b->next->size;b->next=b->next->next;}
        else b=b->next;
    }
}
int usb_dma_coherent(const void *p)
{return (uintptr_t)p>=(uintptr_t)__usb_nocache_start && (uintptr_t)p<(uintptr_t)__usb_nocache_end;}
