# Standalone R5 USB microSD storage

The storage path is R5/FreeRTOS → PS USB0/DWC3 xHCI → USB5744 hub → USB2244
reader → FAT microSD volume → `KR260A.CFG` / `KR260B.CFG`. A53 Linux is not used.

The carrier connection and reset assignments are documented in AMD's
[KR260 U-Boot device-tree contribution](https://qemu.googlesource.com/u-boot/+/baba22addd2c08789325f798a22c2b568538cacb).
The implementation uses the pinned BSD libpayload USB subset under
`third_party/libpayload_usb` and FatFs R0.15 under `third_party/fatfs`.
Upstream licenses remain in source files; local changes are described in their
README files. No precompiled USB library is required.

## Initialization and ownership

FSBL must supply the existing PS clocks, MIO, GTR and wrapper configuration.
Before starting the sensor task, R5 startup accesses the carrier reset device
(I2C1 address `0x11`, register `0xDB`) and changes only USB0 PHY, SD and USB0 hub
reset bits (0, 2, 3), preserving Ethernet and USB1 state. It selects PCA9546
channel 0 at `0x74`, configures USB5744 at `0x2D`, issues SMBus attach, then closes
the mux. The sensor task owns I2C1 after startup; hotplug polls use USB only.

USB0 is placed in host mode and libpayload initializes xHCI command/event rings,
root-hub enumeration, external hubs and SCSI Bulk-Only Transport. Operations are
polled; no USB interrupt handler is installed. USB1 is not initialized here.
Only a USB2244-family reader (`0424:2240`) with 512-byte sectors and capacity
within the backend's signed 32-bit sector range is selected for configuration.
External thumb drives are not selected as substitute configuration storage.

One caller owns USB/FatFs: startup initially, then the HTTP task. Ordinary
network/STP configuration reads use RAM only. Configuration status and explicit
saves probe the card; there is no continuous storage-poll task. Card insertion
is recognized on Reload status or a configuration API request. Each probe
remounts FAT, discarding cached filesystem metadata from a replaced card.
A newly inserted card does not silently replace the running settings.

See [memory ownership](memory-map.md) for the dedicated 1 MiB USB DMA pool.
The stack uses a 64 KiB bounce buffer for cached user buffers. R5 memory barriers
order ownership changes; Ethernet DMA remains in its separate reservation.

## Filesystem and failures

Use an already formatted FAT12/16/32 card, preferably FAT32. exFAT is not enabled;
large SDXC cards commonly need formatting externally before use. Firmware never
formats a card. FAT's first discoverable volume is mounted. No card or no valid
configuration at startup selects defaults. No card means no successful save.
Unrecognized or oversized configuration files disable saves; other files are
left untouched. Removing a card keeps the RAM settings active until restart.

Writes require successful FAT synchronization, close and readback. USB2244
returns ILLEGAL REQUEST / INVALID COMMAND (05/20/00) for SYNCHRONIZE CACHE(10).
A compatibility path accepts completed write-through transfers only for
`0424:2240`, that exact sense result, and a complete valid MODE SENSE response
without enabled write caching or write protection. The board's response contains
only flexible-disk page 05. This follows the absent-cache-page convention in
[Linux sd](https://github.com/torvalds/linux/blob/master/drivers/scsi/sd.c), scoped
to this reader. Transport errors, other sense codes, malformed/truncated mode
responses and reported write-back caching still fail saves. Two file generations preserve a prior valid
record during interrupted payload writes, subject to FAT/card metadata power-loss
limitations. See [record layout and authentication](configuration.md).

## Validation and remaining board work

The all-counter R5 build and host tests pass. Automated tests exercise real
FatFs on a RAM disk, absence/replacement/failures, file preservation, DMA allocator
alignment/reuse, SCSI short-transfer/error handling, configuration recovery and
HTTP authentication. Existing Ethernet/statistics and browser tests also pass.

## Board verification, 2026-09-24

Downloaded through hw_server `10.0.1.107:3121`, with UART at `10.0.1.107:2323`.
The card enumerated as 31,116,288 sectors of 512 bytes (about 15.93 GB decimal),
and its FAT volume mounted. An absent configuration selected defaults. An
unauthenticated save returned 401; an authenticated save returned 200 after
readback. A temporary PL1 disable survived full PS/FSBL/USB reinitialization.
All ports were then restored, saved, and verified after another full reset.
Final configuration reports `saved=true`, `writable=true`, `admin=31`, DHCP.
The first allocated MAC acquired **10.0.1.104**.

The current default FPGA build exposes only standard counters, so this check
used the previously validated `build/r5/ingress_pipeline_validation/kr260_ingress_pipeline.bit`
with firmware `STATS_DDR=1 STATS_DEBUG=1`. Capability readback was `0x53540107`.
This bitstream predates the optional STP hooks; STP remains disabled. GEM1 was
up at 1000 Mb/s; other physical links were down. SNMP and sensor reads succeeded,
with no packet-error, AXI-error or collector-timeout counts in the sampled data.

A final Ethernet-bound ping run initially lost 9 of 10 replies, then recovered
without resetting firmware. JTAG showed the idle task running, DMA without error,
and link admission intact. Subsequent normal and Ethernet-bound full-MTU pings
passed. A subsequent 30-packet Ethernet-bound full-MTU run had no loss while
ten concurrent configuration/card-status reads all succeeded. The cause of this transient is unconfirmed; it is not evidence of a USB
storage failure or proof that the network issue is resolved.

Physical power-cycle retention, removal/reinsertion and card-replacement tests
remain pending. Full reset/reload is verified, not a power-failure durability test.
Local validation logs are under `build/r5/sd_validation/` (ignored artifacts).
