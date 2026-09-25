# Open Ethernet Switch IP repository

The five `manifest.json` files are the source of truth for the reusable
digital blocks. `board.json` lists the KR260 physical shell, vendor IP and
constraints. Paths are relative to the repository root. Existing leaf RTL
stays in `rtl/`; each dependency has one editable source copy.

| Catalog IP (`ghlhub.org:ethernet:<name>:1.0`) | Top module | Responsibility |
| --- | --- | --- |
| `switch_fabric` | `switch_fabric` | Five physical packet streams, CPU virtual port, forwarding, shared buffers, DDR masters, fabric counters |
| `gem_port` | `switch_gem_port` | One PS external-FIFO bridge, RX/TX CDC and local packet counters |
| `pl_port` | `pl_gmii_mac_top` | One GMII MAC, packet-stream adapters, local counters and AXI-Lite registers |
| `sfp_port` | `sfp_port_top` | One 1000BASE-X MAC/PCS, negotiation, packet adapters and counters |
| `management` | `rx_diag_regs` | Existing AXI-Lite configuration, link control, status and statistics mailbox |

The first partition retains RGMII I/O/MDIO, GTH/clock generation and SFP
sideband handling in the board layer. These physical shells are **not yet
inside the port IPs**. The production `system.bd` instantiates all seven digital catalog cells
through `production.tcl`. `rtl/switch_top.sv` remains the native simulation
assembly. `switch_stats_router.sv` is a small BD module reference preserving
the existing 13-bank mailbox routing. See [migration and verification](../docs/ip-partitioning.md).

## Generate and validate a catalog

Run from the repository root, with Vivado 2026.1 on `PATH`:

```sh
vivado -mode batch -nolog -nojournal -source ip_repo/package.tcl
python3 scripts/check_ip_catalog.py build/ip_catalog
vivado -mode batch -nolog -nojournal -source ip_repo/validate.tcl -tclargs build/ip_catalog
python3 scripts/check_ip_catalog.py build/ip_catalog --bd build/ip_refactor/partition_validation
python3 scripts/check_ip_equivalence.py --packaged-bd build/ip_refactor/partition_validation --catalog build/ip_catalog
```

Packaging produces relocatable `component.xml` files and source snapshots
under `build/ip_catalog/`. Add that generated directory to Vivado's
`ip_repo_paths`. Generated source copies are not editable inputs. Packaging
refuses to overwrite an existing catalog; supply a fresh output directory
with `-tclargs build/ip_refactor/catalog_name` when rebuilding it.

`validate.tcl` creates a separate `partition_validation.bd` with seven
instances (fabric, two GEM, two PL MAC, SFP and management). All ten
physical packet-stream connections are present. The remaining interfaces
are exposed as external test boundaries. Its fabric uses both optional
counter groups and a short aging divider for the simulation fixture.
Its automatically assigned addresses and external clocks are **not a KR260
deployment configuration**.

## Build and simulation

```sh
python3 scripts/ip_sources.py --board-only
make -C sim sim-switch-top sim-ingress sim-bufmgr sim-statistics
make -C sim sim-ip-equivalence
KR260_PROJECT_DIR="$PWD/build/ip_refactor/production_bd/project" STATS_DDR=1 STATS_DEBUG=1 \
  vivado -mode batch -nolog -nojournal -source build/build_kr260.tcl -tclargs impl
vivado -mode batch -nolog -nojournal -source ip_repo/review_board.tcl -tclargs \
  build/ip_refactor/production_bd/project/kr260_switch.runs/impl_1/kr260_top_routed.dcp \
  build/ip_refactor/production_bd/reports
```

The board build checks catalog source hashes before using its staged RTL.
Only physical-shell RTL and the mailbox router are added directly; digital
RTL comes from the catalog cells. Simulation resolves the same manifests.
`KR260_IP_CATALOG` selects an alternative generated catalog directory.
The board script retains its usual `build/vivado_kr260` default; the
explicit output override preserves the existing project during migration.
Firmware retains the existing matching `STATS_DDR`/`STATS_DEBUG` options
and register ABI. No firmware changes are required by this partition.

## Independent IP regression suites

Each package owns a `tests.json` list, run by `scripts/check_ip_tests.py`.
The runner compiles only that IP's manifest dependencies plus explicitly
listed test-boundary support. It independently elaborates the public top,
then runs the behavioral cases. `--catalog` uses the staged RTL of that
specific package after auditing its metadata and source hashes.

```sh
# All five IPs, from editable sources:
make -C sim sim-ip-tests
# One IP while developing it:
python3 scripts/check_ip_tests.py --core gem_port
# Run against a generated catalog:
make -C sim sim-ip-tests-packaged IP_CATALOG=../build/ip_catalog
# Native + packaged suites, followed by all four whole-switch comparisons:
make -C sim sim-ip-regression
```

| Package | Behavioral coverage |
| --- | --- |
| GEM | Public wrapper packet/CDC regression at 125/25/2.5 MHz; RX/TX counter accounting |
| PL | Public MAC loopback/line-rate/counters; adapters, reset/reclock |
| SFP | Public MAC/PCS loopback; negotiation, clock correction, TX alignment, RX preamble |
| Fabric | DMA burst pipeline/backpressure/reset; buffer ownership; forwarding/learning/control traffic; CPU DDR transfers; AXI counters |
| Management | AXI-Lite controls/diagnostics; mailbox CDC, clear races, saturation, response backpressure and stopped-clock retry |

The 19 cases reuse the established self-checking benches. The GEM bench can
select the public `switch_gem_port` wrapper instead of its bridge leaf.
Fabric cases exercise constituent blocks; the retained whole-switch miter
checks their assembly. They do not constitute a new randomized six-port
concurrent scoreboard or physical timing/CDC sign-off.

Each compile/simulation has a wall-clock timeout. Nonzero exits, explicit
FAIL/FATAL/ERROR messages, failed test summaries and missing success markers
fail the runner, including legacy benches that report failure via `$finish`.
Per-case logs and a completion-marked JSON report live under
`build/ip_refactor/ip_tests/{native,packaged}/`. Running a selected core
replaces that mode's report with the selected run only.

The catalog audit checks VLNV identity, source contents and relocatable
paths, clock associations, complete AXI/AXI-Stream port mappings and modes,
and packet-stream widths/directions. Generate a fresh catalog using
`package.tcl` before testing changed RTL; stale snapshots deliberately fail.
The existing `validate.tcl` and generated-production-BD equivalence checks
remain integration gates after packaging or connectivity changes.
