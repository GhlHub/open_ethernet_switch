# Open Ethernet Switch

A work-in-progress FPGA Ethernet switch for the AMD Kria KR260, with an initial R5
FreeRTOS control plane. The current RTL joins port adapters, MAC
learning/lookup/aging, and a shared DDR packet-buffer architecture under
the reusable blocks described in [`ip_repo`](ip_repo/README.md), with
`rtl/switch_top.sv` retaining the native simulation assembly.

The source now adds [classic STP/RSTP selection and persistent web controls](docs/spanning-tree.md).
Fabric/management 2.1 and the matching firmware are deployed with STP disabled;
STP/RSTP board qualification is deferred.

The current 2026-09-27 lab build uses fabric/management 2.1 and GEM 2.0,
with the switch fabric at 125 MHz. Independent statistics mailboxes provide
per-bank clock/freshness reporting (ABI 2). PL MAC 1.2 and PHY-management 1.1 support full-duplex
10/100/1000 Mb/s on both PL copper ports. SFP 1.1 remains 1G.
Production uses nine catalog instances from six reusable IP kinds.
It includes [CPU TX frame metadata](docs/cpu-tx-metadata.md), pipelined CPU DDR
writes and a [low-priority MAC-table dump master](docs/mac-table-dump.md).
The public `/mac-table` web page displays MAC addresses, ports and ages; its
**Refresh MAC table** button requests a scan. Opening/reloading the page uses
cached data; no automatic scans are scheduled. The latest firmware source also
adds [passive IPv4 discovery](docs/web-interface.md#passive-ipv4-discovery-2026-09-27-deployed)
to this page; it is deployed and verified on the board.

The matching FPGA and R5 firmware are deployed over JTAG at DHCP address
`10.0.1.104`. Routed timing passes (fabric +1.710 ns setup; overall +0.018 ns
setup / +0.010 ns hold). Earlier speed qualification passed both PL ports at
10, 100 and 1000 Mb/s. The current image adds stopped-clock isolation and
public SNMP/web bank availability reporting.
See [deployment evidence](docs/verification.md#2026-09-27-interrupt-driven-cpu-packet-dma)
and the [current backlog](docs/inventory.md#current-remaining-work).

CPU TX/RX completion is interrupt-driven, with blocked-task wakeups and bounded
RX batches. Hardware verification passed 2,000 CPU and 100 forwarded full-size
pings without loss, concurrent HTTP/SNMP, and zero DMA errors or TX timeouts.
The configuration page shows the active IPv4 address, netmask and default gateway
above the saved settings, and uses wider address and credential fields. See
[web interface](docs/web-interface.md).

A [screw-fastened KR260 clamshell](mechanical/kr260-enclosure/README.md) includes
print-ready STLs, assembly STEP, source and a measured carrier-fit report.
Its CAD checks pass; physical print fit and enclosed cooling remain untested.

The intended port map is two PS GEM ports, two PL Ethernet ports, one SFP port,
and one virtual CPU port. The default SFP build is 1G 1000BASE-X.
A [selectable 10GBASE-R MAC/PCS and 128-bit SFP datapath](docs/sfp-10g.md)
is available with `KR260_SFP_MODE=10g`. A [runtime dual-rate build](docs/sfp-dual.md)
uses `KR260_SFP_MODE=dual` for 1G/10G selection without reloading the FPGA.
The dual-rate image is currently running through volatile JTAG. Hardware tests
verified 1G forwarding, Auto recovery, and a hot swap to an XZSNET copper
module with a 10G host link through a 2.5G-capable switch. Small packet losses
also appeared on copper-only controls; loss-free operation, sustained rate
conversion and actual copper-rate confirmation remain open. See the
[verification record](docs/verification.md). Boot flash was not changed.

The board top includes automatic PL PHY initialization and link polling,
RGMII receive clock adaptation, calibration gating, link-event interrupts,
software-controlled port flushing, and SFP I²C/sideband control. The GEM bridges
carry whole 16-bit words across the clock boundary and use buffered TX start
permits. The switch fabric now runs at 125 MHz; MAC adapters transfer whole
words and the egress frame RAM is prefetched for continuous streaming. The board top connects the digital switch to the PS external GEM FIFOs,
DDR interconnect, CPU-facing AXI DMA, two RGMII ports, and the SFP GTH path.
Vivado build scripts and three IP configurations are included. Existing local
implementation reports show a generated bitstream and positive setup/hold
slack under the current constraints. R5 hardware bring-up now demonstrates UART, timers, DHCP acquisition and ping through all four copper Ethernet ports via
the fabric CPU port. Cable moves retained reachability at `10.0.1.214` on the
running debug image. See the [four-port results](docs/verification.md#four-copper-ports-passing-dhcp-address-ping-2026-09-20).
The SFP path now acquires the same DHCP address through an Ipolex copper SFP
and passes settled small/full-MTU ping tests on the debug image; startup loss
and isolated bring-up errors remain under investigation. The managed switch
RX-error counter subsequently remained stable at 803. Together with the
four copper-port results, this establishes the
`20260920-all_ports_passing_dhcp_ping` basic-connectivity milestone.
A subsequent intermittent-loss investigation captured SFP GTH decoder errors;
the receiver now explicitly uses LPM equalization. Initial LPM testing passed
300/300 full-MTU pings to an endpoint through GEM0 and 300/300 patterned
full-MTU CPU pings, with no SFP MAC receive errors. A brief post-boot
interruption in that debug run remains unexplained. The normal image now
runs without ILAs or a debug hub and includes ingress-port exclusion on MAC
lookup hits; it passed DHCP and 300/300 full-MTU pings to both CPU and GEM0
endpoint with zero SFP receive errors. See [SFP results](docs/sfp-debug.md).
**Sustained throughput, fault recovery, remaining CDC review and complete SFP
hardware validation remain pending.**

- [IP partitioning, packaging and verification](docs/ip-partitioning.md)
- [Architecture diagrams and packet flow](docs/architecture.md)
- [Memory map, cache policy and ownership](docs/memory-map.md)
- [Statistics and environmental monitoring](docs/statistics.md)
- [SNMP counter and sensor access](docs/snmp.md)
- [MAC-table dump registers, records and DMA ownership](docs/mac-table-dump.md)
- [Web port configuration, statistics and manual MAC-table view](docs/web-interface.md)
- [PL copper full-duplex 10/100/1000 implementation](docs/pl-ethernet-speeds.md)
- [PS Ethernet speeds and full-duplex advertisement](docs/ps-ethernet-speeds.md)
- [R5 FreeRTOS startup, timers and networking](software/r5/README.md)
- [Minimal A53 Linux boot alongside the R5 switch](software/linux/README.md)
- [Persistent settings and administrator authentication](docs/configuration.md)
- [Standalone R5 USB microSD storage](docs/usb-storage.md)
- [Source inventory and development backlog](docs/inventory.md)
- [Board wiring, clock plan, and integration gaps](docs/board-integration.md)
- [GEM1 ILA debugging and transmit fixes](docs/gem1-debug.md)
- [SFP module, GTH clock/reset and receive-status investigation](docs/sfp-debug.md)
- [Simulation and lint results](docs/verification.md)
- [CDC review and remaining assumptions](docs/cdc-review.md)
- [Imported source and license notices](docs/source-notices.md)

## Current management interface

The current DHCP address is **10.0.1.104**. Viewing
[port configuration](http://10.0.1.104/configuration) and
[live statistics](http://10.0.1.104/statistics) stays public; configuration
changes require administrator authentication (default `admin` / `admin`).
Statistics refresh every second and are also available through SNMP.
Settings are saved on the FAT32 microSD card through the standalone R5 USB
host stack. Missing cards or records select defaults; saves require a card.
See [configuration](docs/configuration.md) for the stored settings and
supported port capabilities.

The digital and PL PHY-management partitions are deployed with all counter
groups enabled. Both PL PHY controllers report successful initialization and
valid polling; live packet tests cover the connected GEM1 uplink and PL0 miner.
RGMII and SFP physical-shell packaging, complete CDC review and broader traffic
qualification remain pending. DHCP waits one second after admitted-link
readiness before its first attempt. Four HTTP workers handle concurrent clients.
See [startup and HTTP findings](docs/startup-and-http-investigation.md) and
[current verification](docs/verification.md) for historical issues and test limits.
See [interface contracts](ip_repo/INTERFACES.md),
[partitioning](docs/ip-partitioning.md) and
[verification](docs/verification.md) for scope and evidence.

## Source layout

| Directory | Contents |
| --- | --- |
| `ip_repo/` | Six IP manifests including PL PHY management, extracted fabric/GEM wrappers, packaging and validation scripts; generated catalog lives in `build/ip_catalog/` |
| `rtl/board/` | Static KR260 board top and PL assembly joining the generated PS block design |
| `rtl/switch_top.sv` | Compatibility wiring assembly around the fabric and physical endpoints |
| `rtl/ps_eth/` | PS GEM external-FIFO to/from AXI-Stream adapters |
| `rtl/pl_gmii/` | PL 1G MAC, stream/RGMII adapters, Clocking Wizard configuration and behavioral models |
| `rtl/sfp_pcs/` | 1000BASE-X PCS and auto-negotiation, SFP MAC/PCS wrapper, GTH wrapper/configuration and behavioral model |
| `rtl/mdio/` | Clause 22 MDIO master, automatic DP83867 setup, AXI-Lite wrapper and portable pin model |
| `rtl/mac_table/` | Header parsing, forwarding decisions, MAC learning, lookup, and aging |
| `rtl/buf_mgr/` | Buffer allocation, reference counts, and destination queues |
| `rtl/dma/` | Physical-port ingress/egress front ends and shared DDR DMA |
| `rtl/cpu_port/` | CPU stream port and dedicated switch-pool DMA |
| `rtl/common/` | FIFOs, reset and port-link synchronizers, and round-robin arbitration |
| `constraints/` | PL RGMII and SFP pins, primary clocks, and implementation CDC path bounds |
| `tb/` | Portable and XSim testbenches, including DMA pipeline/statistics regressions, and an AXI memory model |
| `build/` | Vivado block-design/synthesis/implementation scripts and digital-switch source list |
| `third_party/` | FreeRTOS-LTS submodule (`202604-LTS`), libpayload USB subset, FatFs and SHA-256; provenance retained with each dependency |
| `sim/Makefile` | Icarus simulation, Verilator lint, and XSim targets |

## Run the existing simulations

The inventory baseline was tested with Icarus Verilog 13.0. Run the 25 portable
testbenches from the repository root:

```bash
make -B -C sim sim-mac sim-bufmgr sim-ingress sim-egress \
    sim-ps-eth sim-integ sim-async-fifo sim-pl-gmii \
    sim-sfp-pcs sim-sfp-port sim-cpu-port \
    sim-mac-fwd sim-switch-top sim-gth-sim \
    sim-rgmii-sim sim-pl-clkgen-sim sim-mdio sim-autoneg \
    sim-mac-reset sim-rx-elastic sim-rx-diag sim-mac-adapters sim-pl-linerate
```

Check the final `=== ALL TESTS PASSED ===` or `PASS: errors=0` marker
without any `FAIL:` messages; compound targets must pass every subtest. The existing benches use `$finish` even on failure, so a zero process
exit status alone is not sufficient. Plain `make -C sim sim` runs only the MAC
table test.

The complete inventory includes 26 testbenches: 25 portable benches and one
XSim-only IDELAY calibration bench. See [verification](docs/verification.md)
for fresh results, vendor-FIFO checks and known lint warnings.
[Board build instructions](docs/board-integration.md#board-build-and-implementation-results)
cover Vivado; [third-party setup](third_party/README.md) covers recursive
FreeRTOS-LTS initialization.
