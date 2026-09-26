# Open Ethernet Switch IP repository

The five `manifest.json` files are the source of truth for the reusable
digital blocks. `board.json` lists the KR260 physical shell, vendor IP and
constraints. Paths are relative to the repository root. Existing leaf RTL
stays in `rtl/`; each dependency has one editable source copy.

The production fabric clock is 125 MHz. The production BD audit checks its
frequency metadata, and the routed audit checks the actual 8 ns period.
MAC aging remains 4 Hz. See [deployed validation](../docs/verification.md#2026-09-26-125-mhz-fabric-board-deployment)
and the [future 128-bit SFP interface](../docs/inventory.md#125-mhz-fabric-and-trunk-preparation-2026-09-26-deployed).

| Catalog IP (`ghlhub.org:ethernet:<name>:<version>`) | Top module | Responsibility |
| --- | --- | --- |
| `switch_fabric` | `switch_fabric` | Five physical packet streams, CPU virtual port, forwarding, shared buffers, DDR masters, fabric counters |
| `gem_port` | `switch_gem_port` | One PS external-FIFO bridge, RX/TX CDC and local packet counters |
| `pl_port` | `pl_gmii_mac_top` | One GMII MAC, packet-stream adapters, local counters and AXI-Lite registers |
| `sfp_port` | `sfp_port_top` | One 1000BASE-X MAC/PCS, negotiation, packet adapters and counters |
| `management` (1.2) | `switch_management` | Existing AXI-Lite configuration, link control, status and statistics mailbox |

The first partition retains RGMII I/O/MDIO, GTH/clock generation and SFP
sideband handling in the board layer. These physical shells are **not yet
inside the port IPs**. The production `system.bd` instantiates all seven digital catalog cells
through `production.tcl`. `rtl/switch_top.sv` remains the native simulation
assembly. Management 1.1 owns the existing 13-bank mailbox router internally.
Fabric 1.1 uses the mandatory CPU TX metadata header; management 1.2 reports
that ABI. GEM/PL/SFP packages remain at 1.0. See [migration and verification](../docs/ip-partitioning.md).

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
Only physical-shell RTL is added directly; digital
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
| Management | AXI-Lite controls/diagnostics; mailbox CDC, clear races, saturation, response backpressure and stopped-clock retry; public wrapper bank routing across all 256 indices |

The 20 cases reuse the established self-checking benches. The GEM bench can
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

## Contracts and fresh acceptance flow

[Interface contracts](INTERFACES.md) define clock/reset ownership, packet and
DDR interfaces, register ownership, parameters, bank routing and versioning.
Management 1.1 replaces the old external raw mailbox with per-bank request,
acknowledgment and value pins; firmware addresses and bank numbers are unchanged.
Existing generated catalogs must be regenerated after this change.

From a checkout (the production fixture also reads historical board wiring),
Vivado 2026.1, Python 3 and Icarus Verilog available:

```sh
python3 scripts/verify_ip_flow.py
# Or: make -C sim verify-ip-flow
# Optionally include implementation, bitstream and routed reports:
python3 scripts/verify_ip_flow.py --implement
```

The default uses a new directory under `build/ip_refactor/acceptance_*` and
preserves existing projects/catalogs. `--output` accepts only a new directory;
`--vivado` selects the Vivado executable. It packages the catalog, audits it,
generates and audits the production BD with all counters, runs native and
packaged IP suites, and compares all four native counter combinations plus
the generated production datapath. Every stage has a log, a timeout and a
record in `results.json`; `complete` becomes true only after all stages pass.
Default execution stops before synthesis. The optional routed report stage
collects timing/CDC findings; report generation alone is not timing sign-off.
Board programming and traffic checks remain separate hardware acceptance.

## CPU TX ABI change (2026-09-26)

See [CPU transmit metadata](../docs/cpu-tx-metadata.md). Native counter-option
runs now exercise the current functional regression; generated/native assembly
miters compare the current contract. They do not claim raw-stream historical
equivalence across this intentional ABI change.
