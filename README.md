# Open Ethernet Switch

A work-in-progress FPGA Ethernet switch for the AMD Kria KR260, with a planned
FreeRTOS control plane. The current RTL joins port adapters, MAC
learning/lookup/aging, and a shared DDR packet-buffer architecture under
`rtl/switch_top.sv`.

The intended port map is two PS GEM ports, two PL Ethernet ports, one SFP port,
and one virtual CPU port. **The current SFP design is 1G 1000BASE-X, not 10GbE.**

The integrated digital switch has a passing GEM0-to-CPU smoke test and an
experimental SFP auto-negotiation path. RGMII adapters, PL clock generation,
AXI-Lite MDIO controllers, PL pin constraints, and a GTH wrapper/configuration
exist separately. The GTH configuration now selects X0Y6 and a 156.25 MHz
reference. Board assembly, hardware-ready negotiation, PS/DDR interconnect,
timing closure, and FreeRTOS software remain pending.

- [Architecture diagrams and packet flow](docs/architecture.md)
- [Source inventory and development backlog](docs/inventory.md)
- [Board wiring, clock plan, and integration gaps](docs/board-integration.md)
- [Simulation and lint results](docs/verification.md)
- [Imported source and license notices](docs/source-notices.md)

## Source layout

| Directory | Contents |
| --- | --- |
| `rtl/switch_top.sv` | Six-port digital switch assembly and aging tick divider |
| `rtl/ps_eth/` | PS GEM external-FIFO to/from AXI-Stream adapters |
| `rtl/pl_gmii/` | PL 1G MAC, stream/RGMII adapters, Clocking Wizard configuration and behavioral models |
| `rtl/sfp_pcs/` | 1000BASE-X PCS and auto-negotiation, SFP MAC/PCS wrapper, GTH wrapper/configuration and behavioral model |
| `rtl/mdio/` | Clause 22 MDIO master, AXI-Lite wrapper, and portable pin model |
| `rtl/mac_table/` | Header parsing, forwarding decisions, MAC learning, lookup, and aging |
| `rtl/buf_mgr/` | Buffer allocation, reference counts, and destination queues |
| `rtl/dma/` | Physical-port ingress/egress front ends and shared DDR DMA |
| `rtl/cpu_port/` | CPU stream port and dedicated switch-pool DMA |
| `rtl/common/` | FIFOs and round-robin arbitration |
| `constraints/` | PL RGMII pins, I/O standards, and primary input clocks |
| `tb/` | Eighteen testbenches and an AXI memory model |
| `sim/Makefile` | Icarus simulation, Verilator lint, and XSim targets |

## Run the existing simulations

The inventory baseline was tested with Icarus Verilog 13.0. Run all eighteen
testbenches from the repository root:

```bash
make -B -C sim sim-mac sim-bufmgr sim-ingress sim-egress \
    sim-ps-eth sim-integ sim-async-fifo sim-pl-gmii \
    sim-sfp-pcs sim-sfp-port sim-cpu-port \
    sim-mac-fwd sim-switch-top sim-gth-sim \
    sim-rgmii-sim sim-pl-clkgen-sim sim-mdio sim-autoneg
```

Each testbench must print `=== ALL TESTS PASSED ===` without any `FAIL:`
messages. The existing benches use `$finish` even on failure, so a zero process
exit status alone is not sufficient. Plain `make -C sim sim` runs only the MAC
table test.

As inventoried on 2026-09-18, all eighteen simulations have passing results:
five new or affected tests passed this update, with thirteen results retained
for unchanged source and recipes. Thirteen of sixteen distinct lint targets
pass; the PL MAC, SFP port, and switch top still exit on warnings. See the
[verification report](docs/verification.md) for coverage and limitations.
