#include "mac_dump.h"
#include "board.h"
#include "xil_cache.h"

#define ABI 0x4d445001u
#define DEST 0x04u
#define CONTROL 0x08u
#define STATUS 0x0cu
#define COMPLETED 0x10u
#define ERROR_CODE 0x14u
#define BUSY 1u
#define DONE 2u
#define ERROR 4u
static struct mac_dump_record *owned;
_Static_assert(sizeof(struct mac_dump_record) == 16, "MAC dump record ABI");

enum mac_dump_result mac_dump_start(struct mac_dump_record *buffer, size_t bytes)
{
    uintptr_t address = (uintptr_t)buffer;
    if (owned) return MAC_DUMP_BUSY;
    if (!buffer || bytes < MAC_DUMP_BYTES ||
        (address & (MAC_DUMP_ALIGNMENT - 1)) || address > 0x7fff8000u)
        return MAC_DUMP_BAD_BUFFER;
    /* This function requires the matching bitstream. An absent AXI slave can
     * cause a bus exception; ABI checking is not hot-plug discovery. */
    if (mmio_read(MAC_DUMP_BASE) != ABI) return MAC_DUMP_UNAVAILABLE;
    if (mmio_read(MAC_DUMP_BASE + STATUS) & BUSY) return MAC_DUMP_BUSY;
    owned = buffer;
    /* HP0 is non-coherent: clean dirty CPU lines before giving DDR to DMA,
     * then invalidate only after the final AXI response has been consumed. */
    Xil_DCacheFlushRange(address, MAC_DUMP_BYTES);
    barrier();
    mmio_write(MAC_DUMP_BASE + DEST, (uint32_t)address);
    mmio_write(MAC_DUMP_BASE + CONTROL, 1);
    return MAC_DUMP_STARTED;
}

enum mac_dump_result mac_dump_poll(uint32_t *completed_bytes, uint32_t *error_code)
{
    if (!owned) return MAC_DUMP_IDLE;
    uint32_t status = mmio_read(MAC_DUMP_BASE + STATUS);
    if ((status & BUSY) || !(status & DONE)) return MAC_DUMP_BUSY;
    barrier();
    Xil_DCacheInvalidateRange((uintptr_t)owned, MAC_DUMP_BYTES);
    barrier();
    if (completed_bytes) *completed_bytes = mmio_read(MAC_DUMP_BASE + COMPLETED);
    if (error_code) *error_code = mmio_read(MAC_DUMP_BASE + ERROR_CODE);
    owned = NULL;
    return status & ERROR ? MAC_DUMP_ERROR : MAC_DUMP_DONE;
}
