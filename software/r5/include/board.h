#ifndef SWITCH_BOARD_H
#define SWITCH_BOARD_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#define DIAG_BASE 0x80100000UL
#define DMA_BASE 0x80000000UL
#define LINK_SET 0x0c
#define LINK_CLR 0x10
#define LINK_STATUS 0x14
#define PCS_STATUS 0x20
#define CPU_PORT_MASK 0x20u
#define PHYSICAL_PORT_MASK 0x1fu
static inline uint32_t mmio_read(uintptr_t p) { return *(volatile uint32_t *)p; }
static inline void barrier(void) { __asm volatile("dsb sy" ::: "memory"); }
static inline void mmio_write(uintptr_t p, uint32_t v) { *(volatile uint32_t *)p=v; barrier(); }
void board_console_init(void);
void board_init(void);
uint64_t board_timestamp(void);
uint32_t board_timestamp_hz(void);
void board_assert(const char *, unsigned);
bool board_phy_mask(uint8_t *mask);
void board_link_task(void *unused);
void network_start(void);
void network_link_changed(bool up);
bool fabric_dma_init(void);
bool fabric_dma_send(const uint8_t *p, size_t n);
size_t fabric_dma_receive(uint8_t *p, size_t capacity);
bool fabric_dma_healthy(void);
#endif
