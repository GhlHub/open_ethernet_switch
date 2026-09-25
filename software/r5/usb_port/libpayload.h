#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <sys/time.h>
#include "libpayload-config.h"
typedef uint8_t u8; typedef int8_t s8; typedef uint16_t u16; typedef int16_t s16;
typedef uint32_t u32; typedef int32_t s32; typedef uint64_t u64; typedef int64_t s64;
#undef __packed
#define __packed __attribute__((packed))
#define __printf(a,b) __attribute__((format(printf,a,b)))
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define MIN(a,b) ((a)<(b)?(a):(b))
static inline u32 read32(const volatile void *p) {return *(const volatile u32 *)p;}
void *usb_malloc(size_t n);
void *usb_calloc(size_t n,size_t size);
void *usb_memalign(size_t align,size_t n);
void usb_free(void *p);
void usb_udelay(unsigned us);
void usb_mdelay(unsigned ms);
int usb_gettimeofday(struct timeval *tv, void *tz);
void usb_fatal(const char *fmt,...) __attribute__((noreturn));
int usb_dma_coherent(const void *p);
#define malloc usb_malloc
#define calloc usb_calloc
#define free usb_free
#define memalign usb_memalign
#define dma_memalign usb_memalign
#define xzalloc(n) usb_calloc(1,n)
#define dma_initialized() 1
#define dma_coherent(p) usb_dma_coherent(p)
#define udelay usb_udelay
#define mdelay usb_mdelay
#define gettimeofday usb_gettimeofday
#define fatal usb_fatal

#define div_round_up(n,d) (((n)+(d)-1)/(d))
