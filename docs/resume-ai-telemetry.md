# Resume point: A53 Linux and AI traffic telemetry

Saved after the minimal Linux boot and Telnet console fix. No telemetry hardware
or Linux DMA driver has been implemented yet. The user requested this handoff
note; the next implementation step was recommended but has not yet been started.

## Intended direction

Monitor switch traffic with FPGA header parsing and flow statistics, then use
inference/anomaly detection to identify interesting conversations and trigger
selective captures. A53 software performs correlation, baseline/model updates,
and postprocessing. Keep monitoring off the forwarding critical path: a full
telemetry queue or stopped Linux reader must never stall normal forwarding.

The K26 has four A53 cores and two R5 cores. The selected architecture is Linux
on the A53 cluster alongside the existing R5-0 FreeRTOS switch application.
Inference applies a model; learning/model updates are a separate activity.
Start with flow features and a software baseline before selecting a PL model.

## Completed and checked in

- Main repository: `/raid/work/kr260-smart-network-auditor`.
  Commit `a6b7f26`: minimal A53 Linux JTAG boot alongside R5 switch firmware.
- Bridge repository: `/raid/work/uart_telnet_bridge`.
  Commit `638c1fb`: stateful Telnet input decoding and carriage-return fix.
- These two commits were **not pushed**. The main worktree was clean after
  committing; this handoff note is a subsequent documentation change.
- The bridge repository has unrelated untracked `node_modules/`, `package.json`,
  `package-lock.json`, and `__pycache__/`; do not include or delete them as part
  of this work.

See [Linux boot instructions and qualification](../software/linux/README.md)
and [memory ownership](memory-map.md) for authoritative details.

## Last verified hardware state

- Linux 6.18.10 booted on all four A53 cores, with a static BusyBox RAM filesystem.
- R5-0 continues running FreeRTOS; R5-1 remains reset.
- Existing dual-rate SFP FPGA image is retained. SFP host link reported 10G;
  the attached unmanaged switch has a 2.5G-capable port. Cable-side negotiated
  speed has not been independently measured.
- Volatile JTAG boot only; QSPI and microSD contents were not changed.
- UART console: `telnet 10.0.1.109 2323`, then Enter for `~ #`.
  No login is required. Ctrl+] then `quit` disconnects the Telnet client.
- Linux has no network interface or SSH yet. R5 management is `10.0.1.104`.
- Hardware server: `tcp:10.0.1.109:3121`.
- The Windows-hosted UART bridge serves one client: a new connection disconnects
  the existing console client. Warn before reconnecting during user interaction.
- The bridge previously passed Telnet `CR NUL` through to BusyBox, causing `?`
  before the next command. The fix handles `CR NUL`, `CR LF`, and fragmented
  negotiation. All ten bridge tests passed. The user restarted the bridge in
  Windows Terminal and confirmed it works. No workaround is now needed.

This describes the last observed state; check board liveness before assuming
that the volatile image survived a later reset or power cycle.

## Ownership and boot constraints

- Linux currently sees only low 2 GiB DDR. Its device tree reserves, with
  `no-map`, the PL packet pool `0x10000000–0x1007FFFF` and the entire R5 region
  `0x20000000–0x21FFFFFF`.
- R5 owns switch management, GEM0/GEM1, PL MAC/control/DMA, USB0 storage,
  I2C1/sensors, and TTC0/TTC1. Linux owns UART1 in the coexistence build.
- R5 build must use `LINUX_CONSOLE=1 STATS_DDR=1 STATS_DEBUG=1` with the currently
  deployed dual-rate bitstream. Incorrect statistics flags disable collection.
  `LINUX_CONSOLE=0` restores standalone UART ownership.
- The minimal Linux DT omits R5-owned peripherals and Linux PS power management.
  FSBL establishes clocks, which remain running. Do not substitute a stock board
  DT or enable clock/power management without reviewing ownership.
- No Linux remoteproc/RPMsg, telemetry driver, coherent DMA, persistent rootfs,
  or suspend support has been added.
- Current packet DMA uses noncoherent HP0 (fabric) and HP1 (R5 CPU-port DMA).
  R5 DMA buffers retain their existing noncacheable policy.

## Build and evidence locations

- Checked-in boot/staging sources: `software/linux/`.
- Checked-in R5 build/console changes: `software/r5/Makefile`, `src/console.c`.
- Generated payloads and evidence: ignored `build/linux/`, including
  `manifest.json`, `boot-final.log`, `uart-final.log`, `linux-final-check.log`,
  `live-results.json`, statistics snapshots, and ping logs.
- BusyBox source/build: `/tmp/kr260-linux-boot/busybox-1.37.0`.
- External kernel/TF-A/PMU artifacts: local AMD EDF 2026.1 deploy directory
  `/tmp/kv260-yocto-2026.1/tmp/deploy/images/`. Source revisions and exact input
  paths are documented in the Linux README. Temporary inputs may need rebuilding
  if cleaned; the scripts do not build the full EDF kernel/firmware themselves.
- Use the switch's own FSBL and PS initialization, not KV260 board boot files.
- Bitstream:
  `build/ip_refactor/sfpdual_release3/project/kr260_switch.runs/impl_dual_timing2/kr260_top.bit`.
- Tools: `/tools/Xilinx/2026.1/`. XSDB is available; the older XSCT entry point
  is disabled in this release. JTAG Linux transfers took several minutes.

## Verification already completed

- Both R5 console configurations built; existing R5 regression suite passed.
- Boot checker validated hashes, ELF load extents and PL/R5 reservations, and
  rejected corrupted hashes, undersized reservations, and a standalone-console
  R5 ELF.
- Linux reported CPUs `0-3`; `/proc/iomem` confirmed both reservations.
- Four CPU-pinned processes hashed a 128 MiB RAM file five times each: 20/20
  matched the host-computed hash. Linux interrupt error count was zero.
- During that load, all 16 R5 statistics HTTP requests succeeded; statistics
  advanced with no read/release/response timeouts. Sensors reported no errors.
- Full-size concurrent pings: R5 `.104` 200/200; SFP endpoint `.135` 200/200;
  PL1 endpoint `.140` 199/200. An idle-A53 PL1 control returned 497/500.
- Intermittent PL1 packet loss remains unresolved. These tests neither establish
  its cause nor prove line-rate forwarding. Do not attribute it to Linux solely
  from this observation; losses existed before the Linux work too.

## Recommended next milestone

Build and verify a **synthetic FPGA-to-Linux telemetry channel first**, then
attach the real header parser/flow tracker. On a user instruction to continue:

1. Review the current block design, PS configuration, address map and minimal
   Linux DT. Define a new analytics-owned DMA interface, interrupt, DDR buffer
   allocation, and software ownership contract without disturbing R5 resources.
2. Add a bounded synthetic record generator with sequence number, timestamp,
   and known test pattern. Specify overflow behaviour and counters. Its output
   must be independent of switch forwarding backpressure.
3. Route analytics DMA through `S_AXI_HPC0_FPD` or HPC1. Hardware coherency needs
   correct AXI attributes, CCI snooping and software memory/DMA configuration;
   merely wiring HPC or setting `dma-coherent` does not establish coherency.
   Review the currently minimal firmware/clock setup before adding Linux drivers.
4. Implement the Linux DMA/ring driver and userspace reader, with interrupts,
   explicit producer/consumer ownership and barriers. Validate data while the
   A53 caches are enabled and under CPU/memory load.
5. Verify sequence integrity, throughput, overruns, ring wrap, reader stop/start,
   and that stopping Linux consumption cannot stall forwarding. Preserve R5
   web/statistics/USB operation during these checks.
6. Replace the generator with bounded Ethernet/VLAN/IPv4/TCP/UDP parsing and
   bidirectional flow aggregation. Handle fragments and unsupported headers
   explicitly. Use flow statistics rather than exporting every packet to Linux.

Later work: statistical baseline/model evaluation, selective capture into a
separate bounded DDR ring, then optional FPGA inference acceleration based on
measured workload. Pre-trigger capture requires a history buffer. The existing
512 KiB forwarding pool is recycled and cannot retain captures indefinitely.

Continue tracking the independent PL1 loss issue before treating traffic-loss
features as reliable training data. Do not begin AI/model work by changing the
forwarding datapath or allocating from R5/PL reserved memory.
