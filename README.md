# Open Ethernet Switch

A work-in-progress FPGA Ethernet switch for the AMD Kria KR260, with a planned
FreeRTOS control plane. The current RTL implements separate port adapters,
MAC-learning/aging logic, and a shared DDR packet-buffer architecture.

The intended port map is two PS GEM ports, two PL Ethernet ports, one SFP port,
and one virtual CPU port. **The current SFP design is 1G 1000BASE-X, not 10GbE.**

This is a collection of simulated subsystems, not yet a complete board design.
The forwarding-decision pipeline, system top level, board interfaces, Vivado
integration, and FreeRTOS software are still pending.

- [Architecture diagrams and packet flow](docs/architecture.md)
- [Source inventory and development backlog](docs/inventory.md)
- [Simulation and lint results](docs/verification.md)
- [Imported source and license notices](docs/source-notices.md)

## Source layout

| Directory | Contents |
| --- | --- |
| `rtl/ps_eth/` | PS GEM external-FIFO to/from AXI-Stream adapters |
| `rtl/pl_gmii/` | PL 1G MAC wrapper and stream/clock adapters |
| `rtl/sfp_pcs/` | 1000BASE-X PCS and SFP MAC/PCS wrapper |
| `rtl/mac_table/` | MAC learning, lookup, and aging |
| `rtl/buf_mgr/` | Buffer allocation, reference counts, and destination queues |
| `rtl/dma/` | Physical-port ingress/egress front ends and shared DDR DMA |
| `rtl/cpu_port/` | CPU stream port and dedicated switch-pool DMA |
| `rtl/common/` | FIFOs and round-robin arbitration |
| `tb/` | Eleven testbenches and an AXI memory model |
| `sim/Makefile` | Icarus simulation, Verilator lint, and XSim targets |

## Run the existing simulations

The inventory baseline was tested with Icarus Verilog 13.0. Run all eleven
testbenches from the repository root:

```bash
make -B -C sim sim-mac sim-bufmgr sim-ingress sim-egress \
    sim-ps-eth sim-integ sim-async-fifo sim-pl-gmii \
    sim-sfp-pcs sim-sfp-port sim-cpu-port
```

Each testbench must print `=== ALL TESTS PASSED ===` without any `FAIL:`
messages. The existing benches use `$finish` even on failure, so a zero process
exit status alone is not sufficient. Plain `make -C sim sim` runs only the MAC
table test.

As inventoried on 2026-09-17, all eleven simulations passed; eight of ten
distinct subsystem lint targets passed. The PL MAC and full SFP wrapper lint
targets exit on warnings. See the [verification report](docs/verification.md)
for exact commands, coverage, and limitations.
