# Open Ethernet Switch

A work-in-progress FPGA Ethernet switch for the AMD Kria KR260, with an initial R5
FreeRTOS control plane. The current RTL joins port adapters, MAC
learning/lookup/aging, and a shared DDR packet-buffer architecture under
the reusable blocks described in [`ip_repo`](ip_repo/README.md), with
`rtl/switch_top.sv` retaining the board-facing wiring interface.

The intended port map is two PS GEM ports, two PL Ethernet ports, one SFP port,
and one virtual CPU port. **The current SFP design is 1G 1000BASE-X, not 10GbE.**

The board top includes automatic PL PHY initialization and link polling,
RGMII receive clock adaptation, calibration gating, link-event interrupts,
software-controlled port flushing, and SFP I²C/sideband control. The GEM bridges
carry whole 16-bit words across the clock boundary and use buffered TX start
permits. The switch fabric now runs at 100 MHz; MAC adapters transfer whole
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
- [Web port configuration and live statistics](docs/web-interface.md)
- [PS Ethernet speeds and full-duplex advertisement](docs/ps-ethernet-speeds.md)
- [R5 FreeRTOS startup, timers and networking](software/r5/README.md)
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

The first digital IP partition is deployed with all counter groups enabled.
It passed the simulation comparisons, routed with WNS +0.018 ns and hold
slack +0.011 ns, and passed settled CPU/endpoint connectivity checks over
GEM1 and PL0. Initial DHCP and endpoint packet losses recovered but remain
unexplained. The production block design now instantiates the digital catalog IPs and
has passed JTAG deployment and settled connectivity checks.
Physical-port packaging, complete CDC review and broader traffic
qualification remain pending.
The latest source additionally moves the statistics decoder into management
1.1 and passes fresh catalog/BD and simulation acceptance; that update has
not yet been implemented or downloaded.
See [interface contracts](ip_repo/INTERFACES.md),
[partitioning](docs/ip-partitioning.md) and
[verification](docs/verification.md) for scope and evidence.

## Source layout

| Directory | Contents |
| --- | --- |
| `ip_repo/` | Five digital IP manifests, extracted fabric/GEM wrappers, packaging and validation scripts; generated catalog lives in `build/ip_catalog/` |
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
