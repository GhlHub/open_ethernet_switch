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
inside the port IPs**. The production assembly instantiates the modules
through `rtl/switch_top.sv`; it does not yet instantiate catalog cells in
the production PS block design. See [migration and verification](../docs/ip-partitioning.md).

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
python3 scripts/ip_sources.py --board
make -C sim sim-switch-top sim-ingress sim-bufmgr sim-statistics
make -C sim sim-ip-equivalence
KR260_PROJECT_DIR="$PWD/build/vivado_kr260_modular" STATS_DDR=1 STATS_DEBUG=1 \
  vivado -mode batch -nolog -nojournal -source build/build_kr260.tcl -tclargs impl
vivado -mode batch -nolog -nojournal -source ip_repo/review_board.tcl
```

The board build and switch-level simulation resolve these same manifests.
The board script retains its usual `build/vivado_kr260` default; the
explicit output override preserves the existing project during migration.
Firmware retains the existing matching `STATS_DDR`/`STATS_DEBUG` options
and register ABI. No firmware changes are required by this partition.
