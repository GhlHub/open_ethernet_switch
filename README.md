# Open Ethernet Switch

A work-in-progress FPGA Ethernet switch for the AMD Kria KR260, with a planned
FreeRTOS control plane. The current RTL joins port adapters, MAC
learning/lookup/aging, and a shared DDR packet-buffer architecture under
`rtl/switch_top.sv`.

The intended port map is two PS GEM ports, two PL Ethernet ports, one SFP port,
and one virtual CPU port. **The current SFP design is 1G 1000BASE-X, not 10GbE.**

The board top includes automatic PL PHY initialization, RGMII receive clock
adaptation, sticky diagnostics, and SFP I²C/sideband control. The GEM bridges
carry whole 16-bit words across the clock boundary and use buffered TX start
permits. The board top connects the digital switch to the PS external GEM FIFOs,
DDR interconnect, CPU-facing AXI DMA, two RGMII ports, and the SFP GTH path.
Vivado build scripts and three IP configurations are included. Existing local
implementation reports show a generated bitstream and positive setup/hold
slack under the current constraints. **Remaining CDC/timing review,
hardware validation of PHY setup, SFP negotiation hardening, and FreeRTOS firmware remain
pending; no board operation has been demonstrated.**

- [Architecture diagrams and packet flow](docs/architecture.md)
- [Source inventory and development backlog](docs/inventory.md)
- [Board wiring, clock plan, and integration gaps](docs/board-integration.md)
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
| `rtl/common/` | FIFOs, reset synchronizer, and round-robin arbitration |
| `constraints/` | PL RGMII and SFP pins, primary clocks, and implementation CDC path bounds |
| `tb/` | Twenty-three testbenches and an AXI memory model |
| `build/` | Vivado block-design/synthesis/implementation scripts and digital-switch source list |
| `sim/Makefile` | Icarus simulation, Verilator lint, and XSim targets |

## Run the existing simulations

The inventory baseline was tested with Icarus Verilog 13.0. Run all twenty-three
testbenches from the repository root:

```bash
make -B -C sim sim-mac sim-bufmgr sim-ingress sim-egress \
    sim-ps-eth sim-integ sim-async-fifo sim-pl-gmii \
    sim-sfp-pcs sim-sfp-port sim-cpu-port \
    sim-mac-fwd sim-switch-top sim-gth-sim \
    sim-rgmii-sim sim-pl-clkgen-sim sim-mdio sim-autoneg \
    sim-mac-reset sim-rx-elastic sim-rx-diag
```

Check the final `=== ALL TESTS PASSED ===` or `PASS: errors=0` marker
without any `FAIL:` messages; compound targets must pass every subtest. The existing benches use `$finish` even on failure, so a zero process
exit status alone is not sufficient. Plain `make -C sim sim` runs only the MAC
table test.

As inventoried on 2026-09-19, all 23 testbenches passed through 21 portable simulation targets; five
vendor-FIFO XSim targets also passed.
Twelve of sixteen distinct lint targets pass; PL MAC, SFP port, switch top
and MDIO targets exit on documented warnings. See the [verification report](docs/verification.md)
for coverage, implementation evidence, and limitations, and the
[board build instructions](docs/board-integration.md#board-build-and-implementation-results)
for Vivado commands.
