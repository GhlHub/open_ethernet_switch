# libpayload USB subset

Source: https://github.com/coreboot/coreboot/tree/7a5f91cae93cc0a5420bb3569f521a8addb228ed/payloads/libpayload

BSD-3-Clause license retained in each source file. USB core, hubs, xHCI and
SCSI Bulk-Only Transport only. R5 compatibility lives in software/r5/usb_port.
No PCI, HID, operating system or A53 dependency.

Local changes: zero-initialize MSC state, refuse invented READ CAPACITY geometry,
check short data/CBW transfers, expose SYNCHRONIZE CACHE(10), and add an R5
acquire barrier after observing an xHCI event cycle bit. Compatibility headers
redirect allocation and DMA to a dedicated non-cacheable pool, time to TTC1,
and long delays to FreeRTOS. The onboard USB2244 reader is the only selected disk.

USB2244 compatibility (board-tested 2026-09-24): SYNCHRONIZE CACHE(10)
returns fixed sense 05/20/00 (unsupported opcode). Only for 0424:2240, after
that exact result and a complete valid MODE SENSE(6) response without an
enabled caching page, sync accepts completed write-through transfers. This
is the Linux sd absent-cache-page convention, restricted to this reader.
Other devices, transport errors, medium errors, enabled caches, write protection
and malformed/truncated mode responses still fail. Successful configuration
saves additionally require file readback. This is not a power-loss guarantee.
