#ifndef TEST_BOARD_H
#define TEST_BOARD_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#define DMA_BASE 0x80000000UL
uint32_t mmio_read(uintptr_t);
void mmio_write(uintptr_t,uint32_t);
void barrier(void);
uint64_t board_timestamp(void);
uint32_t board_timestamp_hz(void);
bool fabric_dma_init(void);
bool fabric_dma_send(const uint8_t *,size_t);
size_t fabric_dma_receive(uint8_t *,size_t);
bool fabric_dma_healthy(void);
#endif
