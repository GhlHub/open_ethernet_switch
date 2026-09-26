# MAC table DMA dump

The fabric 1.2 source adds a CPU-requested, low-priority live scan of the MAC
address table into PS low DDR. It uses a fourth 128-bit HP0 master,
`fabric/m_axi_dump`, on `sc_ddr/S03_AXI`. Packet storage and the CPU virtual
port retain their existing DMA engines. The [web page](web-interface.md#manual-mac-table-snapshots) exposes explicit
manual refresh and cached paginated reads. No interrupt or SNMP table walk is
added.

## Arbitration and burst size

Each chunk contains **16 entries**, read through MAC RAM port A at up to one
entry per fabric clock, buffered locally, and written as one **16-beat,
256-byte AXI INCR burst**. There is at most one write burst outstanding. Full
strobes are used, AWSIZE is 4 (16 bytes), AWLEN is 15, and AXI ID is zero.
A 256-byte-aligned destination means no burst crosses a 4 KiB boundary.

Per-bank priority is learning, aging/flush, then dump. Existing learning/aging
transactions finish normally. Dump grants can be preempted between individual
reads, so a 16-entry read chunk can contain gaps. The dump releases the table
while waiting for DDR and while sending write data. Port B remains dedicated
to forwarding lookups.

At HP0, the dump offers a new AW only when none of the four packet directions
(physical ingress write, physical egress read, CPU write, CPU read) has either
an address request or an outstanding transaction. Tracking ends at B acceptance
or RLAST acceptance. This relies on the current single-outstanding-per-direction
packet engines; revise tracking if their concurrency is increased.

This is **lowest priority at burst admission**. Once AWVALID is offered, AXI
requires it to remain asserted until accepted; packet requests arriving later
cannot retract that burst. SmartConnect itself is not configured for strict
priority or QoS. A newly arriving packet can therefore encounter one admitted
dump burst, and AXI backpressure can extend that delay. There is no absolute
latency bound. Continuous packet activity or table updates may starve a dump.
Sixteen beats bounds each transaction's data volume while amortizing overhead.

The scan is **not an atomic snapshot**: learning, aging and flush continue.
Each 65-bit RAM entry is read together, but rows read at different times can
reflect different table states. Invalid slots are retained; their MAC/mask
contents must be ignored. Age is the current 9-bit remaining-seconds value,
not a timestamp.

## CPU registers

The AXI-Lite slave is on the 125 MHz fabric clock. Control SmartConnect M08
performs the PS control-clock crossing; no extra command mailbox is used.
The assigned window is `0x80110000–0x8011FFFF`; only the low eight address
bits reach the slave. Use aligned 32-bit accesses at the defined offsets.

| Offset | Register | Meaning |
|---|---|---|
| 0x00 | ABI, RO | `0x4D445001` |
| 0x04 | DESTINATION, RW | 32-bit low-DDR destination, 256-byte aligned |
| 0x08 | CONTROL, WO | Write bit 0 = 1 to start |
| 0x0C | STATUS, RO | bit 0 BUSY, bit 1 DONE, bit 2 ERROR |
| 0x10 | COMPLETED_BYTES, RO | Successfully acknowledged whole bursts |
| 0x14 | ERROR_CODE, RO | 0 none, 1 AXI response/ID error, 2 invalid destination |
| 0x18 | ENTRY_COUNT, RO | 2048 |
| 0x1C | RECORD_BYTES, RO | 16 |

Start clears old DONE/ERROR/progress. Completion or failure leaves DONE sticky
until another start. A destination change or start while busy returns SLVERR
without disturbing the transfer. DESTINATION requires all four byte strobes.
CONTROL uses byte-zero strobe and bit zero; other bits have no effect.
Invalid start addresses return SLVERR and set DONE/ERROR with code 2 without
accessing RAM or DDR. Unknown reads return zero; unknown writes are ignored.
The entire 32 KiB destination must fit in the 2 GiB low-DDR aperture
(last permitted start `0x7FFF8000`). This aperture check does **not** allocate
memory or protect firmware, packet pools, PMU reservations or other owners.

A non-OKAY BRESP or nonzero BID stops the scan after consuming that response.
COMPLETED_BYTES excludes the failed burst, which may have modified memory.
There is no transaction timeout, cancellation or per-engine reset. A software
deadline does not give back buffer ownership. Keep polling or perform a
coordinated system reset that also quiesces the interconnect/DDR writers.

## Destination format and ownership

The full dump is 2,048 records × 16 bytes = **32 KiB**, in bank-major order:
`index = bank * 512 + row`. There are 128 bursts. Records are little endian:

| Byte offset | Size | Value |
|---|---|---|
| 0 | 4 | MAC low 32 bits |
| 4 | 2 | MAC high 16 bits |
| 6 | 1 | Port mask |
| 7 | 1 | Reserved, zero |
| 8 | 2 | Age seconds, zero-extended from 9 bits |
| 10 | 2 | Entry index, 0–2047 |
| 12 | 4 | Flags: bit 0 valid (age != 0), others zero |

For example, reconstruct the numerical MAC using
`((uint64_t)record.mac_high << 32) | record.mac_low`. Format its bytes most
significant first for normal colon-separated MAC notation.

The host must allocate the destination exclusively; never point the engine at
the packet pool or the existing HP1 DMA descriptor/bounce-buffer region. HP0 is
non-coherent and uses AxCACHE=0000. For cacheable R5 DDR, clean the whole aligned
buffer before start and invalidate it only after DONE and !BUSY. No CPU access,
reuse or free is allowed in between, including on timeout. Error completion
also requires invalidation before reuse.

`software/r5/include/mac_dump.h` supplies a single-owner task API with this cache
protocol. The caller supplies a 256-byte-aligned array of 2,048
`struct mac_dump_record` objects and serializes API calls; raw CSR access must
not race the driver. `mac_dump_start()` returns STARTED for a successful start; BUSY rejects a new
request without taking ownership of its buffer.
`mac_dump_poll()` returns BUSY until completion, then DONE or ERROR and releases
ownership; subsequent polls return IDLE. Save the returned counts/error code.
The web consumer allocates separate 32 KiB staging and published buffers and
serializes API calls with an HTTP mutex. No periodic scan is scheduled. Use matching hardware:
reading an unmapped AXI window on an older image may raise a bus exception.

## Verification

The dedicated `tb_mac_table_dump` regression checks every row of every bank,
continuous 16-read chunks, concurrent learning/aging and port-B lookup, packet
admission priority, stable AXI signals under backpressure, CSR request rejection,
destination bounds, error termination and restart. Its scoreboard captures live
RAM responses and compares every DDR beat, including age, index and validity.

The full-switch regression starts a dump while exercising all four packet DMA
directions and checks arbitration through outstanding-response gaps, burst
addresses, record ordering and public-register completion. The packaged
production comparison also checks the new interfaces against the native
assembly. R5 host tests check alignment/range rejection, cache ordering,
ownership retention while waiting, and release on successful/error completion.

The matching FPGA image and R5 firmware are now deployed in the lab. Routed
timing, manual web captures and CPU/forwarded-packet checks passed; see the
[deployment evidence](verification.md#2026-09-26-mac-table-dma-and-manual-web-view-deployed)
for coverage and remaining CDC/reset limitations.
