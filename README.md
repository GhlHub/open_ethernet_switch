# Open Ethernet Switch

A work-in-progress FPGA Ethernet switch for the AMD Kria KR260, with an initial R5
FreeRTOS control plane. The current RTL joins port adapters, MAC
learning/lookup/aging, and a shared DDR packet-buffer architecture under
`rtl/switch_top.sv`.

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
See [SFP results](docs/sfp-debug.md).
**Sustained throughput, fault recovery, remaining CDC review and complete SFP
hardware validation remain pending.**

- [Architecture diagrams and packet flow](docs/architecture.md)
- [R5 FreeRTOS startup, timers and networking](software/r5/README.md)
- [Source inventory and development backlog](docs/inventory.md)
- [Board wiring, clock plan, and integration gaps](docs/board-integration.md)
- [GEM1 ILA debugging and transmit fixes](docs/gem1-debug.md)
- [SFP module, GTH clock/reset and receive-status investigation](docs/sfp-debug.md)
- [Simulation and lint results](docs/verification.md)
- [CDC review and remaining assumptions](docs/cdc-review.md)
- [Imported source and license notices](docs/source-notices.md)

## Source layout

| Directory | Contents |
| --- | --- |
| `rtl/board/` | Static KR260 board top and PL assembly joining the generated PS block design |
| `rtl/switch_top.sv` | Six-port digital switch assembly and aging tick divider |
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
| `tb/` | Twenty-six testbenches (one requires XSim) and an AXI memory model |
| `build/` | Vivado block-design/synthesis/implementation scripts and digital-switch source list |
| `third_party/` | FreeRTOS-LTS Git submodule, branch `202604-LTS`; used by the R5 kernel and TCP stack |
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
