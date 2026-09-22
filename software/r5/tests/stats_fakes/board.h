#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#define DIAG_BASE 0x80100000UL
uint32_t mmio_read(uintptr_t p);
void mmio_write(uintptr_t p,uint32_t v);
uint64_t board_timestamp(void);
uint32_t board_timestamp_hz(void);
