#include <stdint.h>
uint32_t mmio_read(uintptr_t);
void mmio_write(uintptr_t, uint32_t);
void barrier(void);

uint64_t board_timestamp(void);
uint32_t board_timestamp_hz(void);
