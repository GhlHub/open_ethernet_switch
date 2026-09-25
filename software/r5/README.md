# R5 FreeRTOS bring-up

Initial firmware for **R5-0 in split mode**. The kernel (11.3.1), GCC ARM_CR5
port and FreeRTOS+TCP come directly from the pinned `third_party/FreeRTOS-LTS`
checkout. The Vitis standalone BSP supplies startup, GIC/TTC drivers and formatting;
its FreeRTOS distribution is not linked. R5-1 must remain parked.

Implemented:

- Hardware initialization of the RPU GIC, two TTC counters, fabric MACs,
  GEM external-FIFO mode, PS PHY management and CPU-port AXI DMA SG rings.
- TTC0 counter 0 (`0xff110000`, IRQ 68): 1000 Hz RTOS tick. TTC1 counter 0
  (`0xff120000`): continuous timestamp counter, input clock divided by 128.
  The generated BSP reports 100 MHz input, giving 781250 timestamp counts/s.
  `board_timestamp()` extends the 32-bit counter to 64 bits; the tick samples
  wraps without resetting it. Interrupts must not be masked for a full counter
  wrap (~91.6 minutes). Resolution is 1.28 microseconds, not one microsecond.
- A single `fabric0` network interface through virtual switch port 5 and AXI
  DMA at `0x80000000`. The GEMs are physical switch ports, not FreeRTOS NICs.
  RX uses 16 SG descriptors; TX uses two alternating descriptors and waits for
  completion. Buffers are copied; D-cache is enabled for application memory, while DMA
  descriptors and bounce buffers occupy a reserved non-cacheable MPU region.
- A 250 ms `vTaskDelayUntil` task samples all five physical ports. GEM0/GEM1
  DP83867 PHYs (addresses 4/9, verified on the development carrier) are read
  over GEM1's shared MDIO bus. PL0/PL1
  PHYs (addresses 2/3) are read through their hardware-maintained PHYSTS
  snapshots: the RTL pollers still run about every 10 ms. Firmware does not
  compete for their MDIO masters. SFP uses PCS state and module/LOS/fault
  signals, since it has no copper MDIO PHY.
- GEM1 supports 10/100/1000 full duplex; GEM0 and the PL/SFP paths currently
  admit only 1 Gb/s full duplex. Lower-speed PL links remain disabled. PHY read
  failures disable the affected link; failed PL hardware polls now invalidate
  their cached state. PS PHY initialization failures are retried on later polls.
- Link-down writes `LINK_CLR` once per transition. Re-enable waits at least
  one poll interval and for flush busy to clear. The CPU port remains enabled
  while all physical ports are down. A DMA fault disables all destinations and
  requires reboot; descriptors possibly owned by DMA are never reused.
- DHCP starts after any admitted physical link has remained available for at
  least one second (evaluated on the 250 ms poll). This does not hold physical
  forwarding. FreeRTOS+TCP handles discovery, request, renewal and rebinding.
  Its maximum retransmission period is 32 seconds, allowing retries after the
  initial 5-second interval; the previous 8-second ceiling suppressed every
  Discover retransmission. After an acquisition attempt
  fails, the firmware waits **60 seconds from failure** and requests another
  attempt through `FreeRTOS_NetworkDown()` in task context. Each subsequent
  failure schedules another 60-second wait. No static fallback address is
  assigned (defaults are zero). The stack may report its default-address event;
  firmware does not treat that event as a DHCP lease. Link recovery starts a
  fresh attempt. Retry policy uses the stack's success/failure trace callbacks.

## Persistent settings

The CPU uses the first of five allocated board MACs, `00:0a:35:0f:37:45`.
microSD settings include the full allocation, administrator password verifier,
port preferences and DHCP/static IPv4. The configuration webpage and
`scripts/configure_switch.py` save them. See [configuration](../../docs/configuration.md)
for supported speeds, storage ownership, authentication status and recovery.
Build with `CONFIG_RECOVERY=1` only for a deliberate JTAG recovery session;
it bypasses saved settings without automatic card writes.

Storage stays entirely on R5: USB0 xHCI, the onboard hub/card reader, and FatFs.
No card or no valid configuration selects defaults; saves require a FAT card.
Viewing stays public, and configuration writes require `admin` / `admin` by
factory default. USB DMA has a separate 1 MiB non-cacheable reservation.
See [USB implementation and board verification](../../docs/usb-storage.md).
The saved DHCP configuration currently acquires `10.0.1.104`.

## Build

Vitis/Vivado 2026.1 and their R5 GCC toolchain are the tested tools. From the
repository root, with the existing Vivado board project generated:

```sh
git submodule update --init --recursive -- third_party/FreeRTOS-LTS
mkdir -p build/r5
source /tools/Xilinx/2026.1/Vivado/settings64.sh
vivado -mode batch -source software/r5/export_hardware.tcl -nolog -nojournal
/tools/Xilinx/2026.1/Vitis/bin/vitis -s software/r5/create_platform.py
make -C software/r5 -j8
make -C software/r5 test
```

Output: `software/r5/out/kr260_r5.elf` and `.map`. Generated XSA, BSP and FSBL
are under `build/r5/`. The platform script reuses its workspace and updates
its hardware on subsequent runs. `XILINX` and `BSP` can be overridden for Make.
The linker script is adapted from AMD's MIT-licensed `lscript_r5.ld.in`.

## Boot and memory contract

Boot through an appropriate ZynqMP FSBL/PMU firmware flow before starting the
ELF: PS clock/reset, DDR, MIO, PS-GTR and carrier PHY reset initialization must
already be complete, and the fabric must be programmed and clocked. Calling
`main()` alone on an uninitialized PS is not supported. Platform creation also
generates an FSBL, but this change does not package or flash a BOOT.BIN.

The development board's hardware server is `10.0.1.107:3121`; its UART telnet
bridge is `10.0.1.107:2323`. After building the platform, firmware and bitstream,
start a volatile JTAG session from the repository root:

```sh
/tools/Xilinx/2026.1/Vitis/bin/xsdb software/r5/boot_jtag.tcl tcp:10.0.1.107:3121 \
  build/r5/ingress_pipeline_validation/kr260_ingress_pipeline.bit
/tools/Xilinx/2026.1/Vitis/bin/xsdb software/r5/status_jtag.tcl
```

This resets the PS, runs the A53 FSBL, selects R5 split mode, programs the PL,
releases PS/PL isolation and starts R5-0. A53-0 stays halted and R5-1 stays in
reset. It replaces the current session but does not write flash. An optional
argument overrides the hardware-server URL. The temporary JTAG boot override
is restored even if FSBL initialization fails. Use `xsdb`; Vitis 2026.1 disables
the older `xsct` entry point.

The platform script selects UART1 for both the application BSP and FSBL BSP,
and refreshes the FSBL's local `psu_init.c/h` from the exported hardware.
Vitis hardware updates alone can retain stale FSBL initialization files.

Use a newly built bitstream containing `PCS_STATUS` at diagnostic offset
`0x20`; the previous bitstream reads zero there and cannot admit SFP traffic.
The exported XSA describes the BD; exporting it does not rebuild the PL RTL.

See the [complete memory map and ownership contract](../../docs/memory-map.md)
for DMA handoffs, register windows and internal FPGA memories.

| Region | Owner |
| --- | --- |
| `0x00000000–0x0000ffff` | R5-0 ATCM reset/startup vectors |
| `0x10000000–0x1007ffff` | Fabric packet pool, exclusively reserved |
| `0x20000000–0x21ff7fff` | R5 firmware and RTOS heap/stacks; cacheable DDR |
| `0x21ff8000–0x21ffffff` | 32 KiB DMA region; normal non-cacheable, shareable, execute-never |

Other processors, boot payloads and OS memory maps must reserve both DDR
reservations (the R5 reservation includes both cacheable and DMA subregions).
D-cache is enabled after a higher-priority MPU region is installed for
`.dma_nocache`. All 18 descriptors and 18 bounce buffers live there, aligned
to 64 bytes; driver state, FreeRTOS heap and stacks retain the BSP's cacheable
DDR mapping. MMIO retains the BSP's non-cacheable attributes.
The DMA section is NOLOAD and explicitly cleared after DMA reset, before
ownership is handed to hardware. The driver still uses memory barriers;
per-packet cache maintenance is unnecessary because DMA never accesses the
cacheable application buffers directly. Instruction caching is unchanged.
The ELF audit checks DMA placement/alignment and application-memory separation.
Startup checks read back MPU registers and confirm SCTLR MPU/D-cache enable bits.

**Future work: review the DMA descriptor and packet-buffer cache policy.**
Keeping both non-cacheable is the initial implementation, not a final performance
decision. Measure CPU cost and throughput, then evaluate descriptor and payload
policies separately, including keeping descriptors uncached while caching packet
buffers. Any cached DMA storage requires explicit clean/invalidate operations at
ownership transfers, cache-line isolation, and tests for ring reuse, reset and
error recovery. Retain the current policy until a replacement is validated.

JTAG reads through the PSU see DDR, not necessarily dirty R5 cache contents.
Values such as `xTickCount`, driver state and the UART software log can therefore
appear stale in `status_jtag.tcl`. Use UART output and live network traffic for
firmware liveness; MMIO and the non-cacheable DMA region remain directly readable.

Board CPU MAC: `00:0a:35:0f:37:45`; use a separate allocation per board before
connecting multiple boards. DHCP transaction/TCP sequence randomness is a
noncryptographic timestamp-seeded PRNG; do not use it for security keys.
The regenerated design enables **PS UART1 at `0xff010000`**, on MIO36/MIO37
through the carrier FTDI console. The platform script selects UART1 for BSP
stdin/stdout. Firmware initializes it to **115200 baud, 8 data bits, no parity,
one stop bit, no hardware flow control** before other board initialization.
Use the carrier UART serial device with those settings.

`console.c` wraps `outbyte` to send output to UART1 and mirror every character
into the 4096-byte RAM log. UART writes use bounded polling; characters that
cannot be sent within the polling limit increment `board_uart_dropped` and
remain in RAM. Before UART initialization, logging uses RAM only. Inspect
`board_log` and `board_log_written` with the debugger (oldest character after
wrap is at `board_log_written & 4095`). The firmware rejects an outdated BSP
that does not select UART1 at build time. Regenerate the XSA/BSP and use the
matching FSBL so the MIO routing, UART reference clock and resets are configured.
Fatal assertions park the CPU and
log the source location; exception vectors park at `r5_fault_handler` for
inspection in a debugger.

## Validation and remaining work

The R5 ELF cross-compiles and links against the generated board BSP. A link-time
audit checks the entry point, ATCM IRQ/SVC targets, resolved symbols and DDR
load ranges. Host tests
exercise link admission/flush delay, tick wrap, DHCP retry scheduling, DMA
padding, descriptor rotation, RX ring wrap, malformed RX, and fail-closed TX
error/timeout behavior. These tests model registers and descriptors, not AXI
hardware or DHCP packets. RTL diagnostics/PHY benches test the read-only PCS
register and poll-failure invalidation/recovery.

JTAG bring-up on 2026-09-20 demonstrated FSBL/DDR initialization, R5 split-mode
startup, physical UART output, advancing RTOS/timestamp counters, both PS PHY
initializations, GEM1 link admission and reception of real Ethernet packets
through the fabric CPU port. A five-second JTAG sample measured 5024 ticks and
3925577 timestamp counts (5041 ms wall time, including read skew), consistent
with the configured rates; this is not precision clock calibration. The PL PHYs
were initialized but disconnected; SFP was absent.

GEM1 ILA debugging corrected the PS FIFO clock selection and a spurious
underrun on the read immediately after EOP. The R5 acquired DHCP address
`10.0.1.214`; five host pings succeeded with zero loss, and GEM1 reported four
successful TX frames and zero underruns before the ping test. See
[ILA captures and regression](../../docs/gem1-debug.md). Sequential cable moves to GEM0, PL1 and PL0 also passed ping at the same
address (15/15, 20/20 and 20/20 in the final samples). See the
[four-port results](../../docs/verification.md#four-copper-ports-passing-dhcp-address-ping-2026-09-20).
Lossless handover, minute-retry timing on the wire, lease renewal, and DMA
stress remain pending.
The JTAG session runs without PMU firmware (the FSBL reports this); full boot
packaging and power-management integration are still pending. PS PHY strap/SGMII and
RGMII delay assumptions require board confirmation. Existing SFP negotiation
simulation-scale timers and interoperability gaps remain; do not treat this
firmware as SFP hardware sign-off. The unacknowledged link-flush protocol still
needs stronger RTL completion semantics; the current guard assumes a running
100 MHz fabric. DMA automatic restart, cache-enabled throughput and production
entropy provisioning are later work.

Register references: [AMD GEM external FIFO register](https://docs.amd.com/r/en-US/ug1087-zynq-ultrascale-registers/external_fifo_interface-GEM-Register),
[AMD TTC driver](https://xilinx.github.io/embeddedsw.github.io/ttcps/doc/html/api/index.html),
and the generated BSP headers/configuration tables. The upstream kernel/TCP
sources in `third_party` define the RTOS port and network-interface contracts.

## SNMP

Read-only SNMPv2c on UDP 161 exposes all compiled-in counters and environmental
readings. Default lab community: `public`; example PEN: `32473`. Configure
`include/snmp.h`; see [SNMP documentation](../../docs/snmp.md) and the supplied
[MIB](../../docs/mibs/KR260-SWITCH-MIB.txt). `make test` exercises the BER engine
and MIB with all four statistics build combinations.

## Statistics and sensors

The standard firmware reads per-port packet/byte counters every 250 ms and
accumulates 64-bit totals. `STATS_DDR=1` and `STATS_DEBUG=1` enable the optional
DDR and debug collectors; use matching FPGA synthesis options. An ABI/options
mismatch disables collection with a UART diagnostic. A separate task samples
PS/PL SYSMON and the carrier's INA260 SOM power monitor every second.

See [statistics.md](../../docs/statistics.md) for the counter definitions,
register protocol, widths, ownership, snapshot API, build examples and
validation limits. The all-counter build was loaded through JTAG on 2026-09-21;
DHCP and full-MTU pings to the R5 and forwarded endpoint passed.

## Web management

The firmware serves `/configuration` and `/statistics` on HTTP port 80 without
login. Configure the five physical ports and view all available statistics and
sensors; statistics refresh every second. Port settings reset on reboot.
See [web interface](../../docs/web-interface.md) for API, behavior, and tests.

GEM1 (right lower, RGMII) supports 10/100/1000 full duplex with selectable
PHY advertisement on the web page. GEM0 (right upper, PS SGMII) remains
1000-only due to the PS interface restriction. Both interfaces report
physical speed via HTTP and SNMP. See [PS speeds](../../docs/ps-ethernet-speeds.md).

Startup timing and the confirmed HTTP connection-capacity limitation are
documented in [the investigation](../../docs/startup-and-http-investigation.md).
