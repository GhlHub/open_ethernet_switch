#ifndef TEST_BOARD_H
#define TEST_BOARD_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#define DMA_BASE 0x80000000UL
#define DIAG_BASE 0x80100000UL
#define CPU_TX_ABI 0x54
#define CPU_RX_TAG 0x50
uint32_t mmio_read(uintptr_t);
void mmio_write(uintptr_t,uint32_t);
void barrier(void);
uint64_t board_timestamp(void);
uint32_t board_timestamp_hz(void);
struct fabric_dma_counters {
    uint32_t tx_irq, rx_irq, error_irq, tx_completed, rx_consumed, rx_dropped, tx_timeouts;
};
extern volatile struct fabric_dma_counters fabric_dma_counters;
void board_dma_irq_enable(void);
void fabric_dma_interrupt(bool receive);
void network_dma_event(bool from_isr);
bool fabric_dma_rx_pending(void);
bool fabric_dma_init(void);
bool fabric_dma_send(const uint8_t *,size_t);
bool fabric_dma_send_directed(const uint8_t *p, size_t n, uint8_t mask);
size_t fabric_dma_receive(uint8_t *,size_t);
bool fabric_dma_healthy(void);
void fabric_dma_last_rx_tag(bool *valid, uint8_t *ingress_port);
#endif
