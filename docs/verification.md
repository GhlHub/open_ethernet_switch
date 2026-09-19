# Design inventory verification

Date: 2026-09-19. All 18 simulation targets and 16 distinct lint targets
were rebuilt/rerun for this inventory. Existing local Vivado implementation
reports were inspected separately; no FPGA build was launched for this
inventory. Incoming source changes were preserved. Additional GEM recovery edits arrived
during the inventory; their three affected simulations and two lint targets
were rerun after reviewing the changes.

| Tool | Observed version |
| --- | --- |
| Icarus Verilog | `13.0 (stable) (v13_0-dirty)`, `/usr/local/bin/iverilog` |
| Verilator | `5.020 2024-01-01 rev (Debian 5.020-1)` |

## Simulation results

All 18 targets were rebuilt with `make -B -C sim TARGET`. Each returned
zero, printed `=== ALL TESTS PASSED ===`, and had no runtime failure markers.
All rows below are fresh results for this update. Icarus warnings remain,
including ignored `unique` case qualities and broadened `always_*` sensitivity.

| Target | Testbench | Observed coverage | Result |
| --- | --- | --- | --- |
| `sim-mac` | [`tb_mac_addr_table.sv`](../tb/tb_mac_addr_table.sv) | Learn two addresses, hit/miss masks, aging expiration | PASS |
| `sim-bufmgr` | [`tb_buf_mgr_core.sv`](../tb/tb_buf_mgr_core.sv) | Unicast, free-list reuse, multi-destination references, zero-mask drop, concurrent requests | PASS |
| `sim-ingress` | [`tb_ingress_top.sv`](../tb/tb_ingress_top.sv) | Odd-length DDR write, bad-frame drop, two concurrent ingress frames | PASS |
| `sim-egress` | [`tb_egress_top.sv`](../tb/tb_egress_top.sv) | DDR read/stream reconstruction, buffer release, two output ports | PASS |
| `sim-ps-eth` | [`tb_ps_gem_axis_bridge.sv`](../tb/tb_ps_gem_axis_bridge.sv) | RX overflow timing and abort termination, flush/next-frame recovery, TX framing and underflow/drain/flush recovery, completion toggle | PASS |
| `sim-integ` | [`tb_egress_gem_tx_integration.sv`](../tb/tb_egress_gem_tx_integration.sv) | Buffer manager + DDR egress + GEM TX adapter; even/odd frame lengths buffered completely before GEM reads | PASS |
| `sim-async-fifo` | [`tb_async_fifo.sv`](../tb/tb_async_fifo.sv) | Ordering across clocks, full/empty behavior, rejected writes when full, sustained FIFO traffic | PASS |
| `sim-pl-gmii` | [`tb_pl_gmii_adapters.sv`](../tb/tb_pl_gmii_adapters.sv) | Stream adapter round trips for 27-, 14-, and 100-byte frames; does not instantiate the MAC | PASS |
| `sim-sfp-pcs` | [`tb_sfp_1000base_x_pcs.sv`](../tb/tb_sfp_1000base_x_pcs.sv) | 16-bit parallel self-loopback; negotiation status, sync acquire/loss/recovery, frame/error propagation | PASS |
| `sim-sfp-port` | [`tb_sfp_port_top.sv`](../tb/tb_sfp_port_top.sv) | MAC + PCS + adapters in digital loopback, 73- and 60-byte frames | PASS |
| `sim-cpu-port` | [`tb_cpu_port_top.sv`](../tb/tb_cpu_port_top.sv) | CPU TX into pool, CPU RX from pool, lengths/content and buffer reuse | PASS |
| `sim-mac-fwd` | [`tb_mac_forwarding_top.sv`](../tb/tb_mac_forwarding_top.sv) | Unknown-destination flood, source learning, subsequent targeted hit, short-frame drop | PASS |
| `sim-switch-top` | [`tb_switch_top.sv`](../tb/tb_switch_top.sv) | Assembled switch: 52-byte unknown-destination frame from PS GEM0 reaches CPU egress byte-for-byte | PASS |
| `sim-gth-sim` | [`tb_gth_sfp_sim_model.sv`](../tb/tb_gth_sfp_sim_model.sv) | Behavioral GTH reset/status, ten parallel words with K flags through three-cycle loopback, forced error assertion/clear | PASS |
| `sim-rgmii-sim` | [`tb_rgmii_gmii_sim_model.sv`](../tb/tb_rgmii_gmii_sim_model.sv) | Behavioral RGMII loopback: 20- and 12-byte frames plus error propagation at byte 5 of a 16-byte frame | PASS |
| `sim-pl-clkgen-sim` | [`tb_pl_eth_clk_gen_sim_model.sv`](../tb/tb_pl_eth_clk_gen_sim_model.sv) | Model lock/startup reset release; measured periods 8 ns, 3.334 ns, 16 ns | PASS |
| `sim-mdio` | [`tb_mdio_controller.sv`](../tb/tb_mdio_controller.sv) | AXI-Lite-driven Clause 22 write framing, modeled PHY read response, BUSY/DONE and W1C status clear | PASS |
| `sim-autoneg` | [`tb_autoneg_1000base_x.sv`](../tb/tb_autoneg_1000base_x.sv) | Two cross-wired PCS instances negotiate default abilities, pass frames both directions, lose link and renegotiate after injected RX corruption | PASS |

The DMA tests use [`axi_mem_bfm.sv`](../tb/axi_mem_bfm.sv), not a real PS DDR
controller. Subsystem tests supply forwarding masks directly;
`sim-switch-top` exercises the real parser/table/mask path for a lookup miss.
Its two independent memory BFMs are kept consistent by copying the physical
memory array into the CPU memory array after a write response. That backdoor
copy does not test shared AXI interconnect arbitration or coherency. Learned
unicast is tested in `sim-mac-fwd`, but not yet end-to-end through the switch.

The egress/GEM content test now waits for the complete frame to enter the
bridge before reading it. That avoids the known fill-rate mismatch for these
short frames; it does not establish uninterrupted streaming at 1 Gb/s.
The GEM bridge test separately forces mid-frame underflow, verifies the drain/
flush response, and checks that the next frame arrives intact. RX tests now
verify bad-frame termination and next-frame recovery after overflow and flush.

The PCS and SFP-port tests directly loop back decoded parallel symbols. The
GTH behavioral model has its own standalone test and is not instantiated by
those benches. No serial link or optical module participates. GEM tests use
behavioral FIFO stimulus, not the hard GEM. The bridge and switch-top benches
connect the newly separated RX and TX clock inputs to the same per-GEM clock;
independent RX/TX clock and reset behavior is not yet covered.

The RGMII model does not instantiate the hardware adapter, its asynchronous
RX FIFO, or delay/DDR primitives. Its loopback clock is derived from the TX
clock, so it does not validate independent-clock behavior. The clock model
ignores `ref_clk_25m_i` and produces free-running nominal clocks; its 3.334 ns
period is approximately 299.94 MHz. This test does not verify the MMCM,
reference-loss behavior, reset reassertion, calibration, or hardware phase timing.

The auto-negotiation test uses two instances of the same PCS RTL with shared
125/62.5 MHz clocks and identical default abilities. It does not cover different
partner implementations, realistic timers, clock drift, Next Page, asymmetric
pause, incompatible abilities, fault policy, or traffic admitted during restart.
The SFP-port and switch-top benches leave the new negotiation status outputs
unconnected; their passing results do not verify link-aware forwarding.

The MDIO bench tests the real master with a copied register shim and portable
tristate pin stage, not the hardware IOBUF. It runs at 125 MHz with divider zero
for speed. It does not establish the default MDC rate, real PHY configuration,
turnaround-error handling, split AW/W channels, response backpressure, or byte-
strobe corner cases. It verifies DONE clearing, not every sticky-status race.

To repeat the simulation inventory:

```bash
make -B -C sim sim-mac sim-bufmgr sim-ingress sim-egress \
    sim-ps-eth sim-integ sim-async-fifo sim-pl-gmii \
    sim-sfp-pcs sim-sfp-port sim-cpu-port \
    sim-mac-fwd sim-switch-top sim-gth-sim \
    sim-rgmii-sim sim-pl-clkgen-sim sim-mdio sim-autoneg
```

Inspect each test's final pass marker and any `FAIL:` messages. Existing tests
use `$finish` on failure as well as success, so process exit status alone is
not a reliable test result. Automated failure propagation remains pending.

## Lint results

All 16 distinct targets were rerun. Thirteen pass without reported warnings;
the PL MAC, SFP port and switch top still fail on warnings:

```bash
make -k -C sim lint-mac lint-bufmgr lint-ingress lint-egress \
    lint-ps-eth lint-async-fifo lint-pl-gmii lint-sfp-pcs \
    lint-sfp-port lint-cpu-port lint-mac-fwd lint-switch-top lint-gth-sim \
    lint-pl-clkgen-sim lint-mdio lint-autoneg
```

| Target(s) | Result |
| --- | --- |
| `lint-mac`, `lint-bufmgr`, `lint-ingress`, `lint-egress`, `lint-ps-eth`, `lint-async-fifo`, `lint-sfp-pcs`, `lint-cpu-port`, `lint-mac-fwd`, `lint-gth-sim` | PASS, no reported warnings |
| `lint-pl-clkgen-sim` | PASS, no reported warnings |
| `lint-mdio`, `lint-autoneg` | PASS, no reported warnings |
| `lint-pl-gmii` | FAIL: Verilator exits due to 31 warnings |
| `lint-sfp-port` | FAIL: Verilator exits due to 37 warnings |
| `lint-switch-top` | FAIL: Verilator exits due to 61 warnings |

All three failing targets report 24 `WIDTHEXPAND` and five `WIDTHTRUNC` warnings
in `open_eth_mac_1g_switch.sv`, plus a `SYMRSVDWORD` warning for `interrupt`.
The remaining warnings are `TIMESCALEMOD`: one for the PL target, seven for
the SFP target, and 31 for the switch top. Warnings were not suppressed to
obtain a clean result.

The Makefile also has `lint-integ`, but it selects `egress_top` as the lint
top and does not represent a separately assembled GEM integration wrapper;
it was not counted as another subsystem check.

There is no `lint-rgmii-sim` target: the behavioral RGMII model uses separate
edge-sensitive drivers on the same outputs. Its Makefile explicitly excludes
it from lint. Neither hardware RGMII nor the hardware clock wrapper is covered
by the portable lint targets.

## Local Vivado implementation evidence

The existing reports identify Vivado 2026.1, `kr260_top`, device
`xck26-sfvc784-2LV-c`, and a routed design. They were written on 2026-09-19
around 00:38–00:39 (report timestamps). An earlier bitstream was recorded before a concurrent rebuild recreated
the generated project directory.
These artifacts were inspected during this update; no clean Vivado rebuild
was performed, so exact source-to-artifact identity remains unverified.

| Evidence | Observed result |
| --- | --- |
| Timing summary | WNS +0.726 ns; TNS 0; WHS +0.010 ns; THS 0; all user-specified timing constraints met |
| Timing completeness | `check_timing` reports 12 input ports without input delays and 18 ports without output delays; these counts differ from the 16 TIMING-18 methodology findings |
| Utilization | 25,527 CLB LUTs (21.80%); 39,696 registers (16.95%); 49.5 BRAM tiles (34.38%); 3/4 MMCMs |
| CDC summary | 10 critical clock-pair groups; no common primary clock with max-delay-datapath-only exceptions |
| Detailed critical CDC | 2,042 CDC-1 unknown 1-bit circuitry; 896 CDC-13 1-bit paths on non-FD primitives; one CDC-14 multi-bit path on a non-FD primitive: **2,939 critical findings total** |
| DRC | Two REQP-1935 RAM collision advisories reported as warnings; no error/critical entries in this report |
| Methodology | 101 findings: 100 warnings and one advisory, including missing I/O delays, unknown CDC logic, auto-derived-clock references, async resets and unconstrained MMCM placement |
| Hardware | No board traffic, link, firmware or throughput result established |

Positive slack applies only to the constraints that exist. It does not
establish complete RGMII timing closure. Likewise, the absence of critical
entries in the DRC report does not mean the CDC report is clean. The latter
includes the former path from each GEM RX FIFO's fabric-domain `empty_o`
register to its GEM-domain `overflow_q` register. The latest RX recovery RTL
removes that dependency and clears overflow from GEM-domain frame completion.
A fresh routed CDC report is needed to confirm the resulting findings.
Other findings involve FIFO storage and need structural/protocol analysis before any waiver.
Whole-clock-domain max-delay constraints do not prove safe synchronization.

The new SFP MMCM's internal 125/62.5 MHz paths remain synchronously timed;
GT interface phase, clock correction and reset recovery still require review
and hardware testing. The new board wrappers, reset helper, PCS clock wrapper
and vendor IP are not exercised by the portable simulation targets.

Build instructions and generated-artifact paths are in
[board integration](board-integration.md#board-build-and-implementation-results).
The scripts generate the normal reports; the detailed CDC report additionally
uses `report_cdc -severity Critical -details` on the routed design. Raw reports,
checkpoints, vendor products and bitstreams are local generated artifacts
and are ignored.
These fingerprints identify the evidence inspected, without claiming a clean
reproduction from this commit:

| Local file under `build/reports/` | SHA-256 |
| --- | --- |
| `impl_timing_summary.rpt` | `c577853c14dc8671068b69114cf312676244bf1ebf6f85a0c7a35d009ee58a78` |
| `impl_utilization.rpt` | `c14f91d76838c4a98bf355e645aab80e80c3c36dfe2ab047d48c2e8bb0027666` |
| `impl_cdc_summary.rpt` | `523844a698ce94990025e9636f7423197792eafa8e51072ea91d2c1a153e726d` |
| `impl_cdc_critical.rpt` | `6f933ba369a0a604ba58458fce9d93f6feb6b6ef633c1e842f92a1990ddd21f2` |
| `impl_drc.rpt` | `54c985e4f2bb6c91695a8dc0fb11148a220b714065d0afae6dc35420eca6eadb` |
| `impl_methodology.rpt` | `98e15cfa71c11c4a505fa646bd433a6ca041efb4dad6eb2a2237041650f8145a` |
| `address_map.txt` | `3eee75085fb888407bd987fb5296874f423ce8ed055af3e83590c5baf1e3b7dc` |

The implementation directory was regenerated by a separate build during this
inventory. The earlier bitstream is no longer available there; the ongoing
build is not counted as a completed validation result for this snapshot.

## Not established by these checks

- Complete six-port operation, shared DDR contention or sustained wire rate.
- FreeRTOS operation, CPU-facing AXI DMA traffic or hard GEM FIFO timing.
- Real PHY/RGMII or SFP/GTH interoperability and negotiated link operation.
- Complete external I/O timing, CDC/reset sign-off or reproducible artifact
  identity from a clean build of this source snapshot.
- Exhaustive malformed-frame, buffer exhaustion, DMA-error or reset recovery.

The portable tools do not compile the hardware GTH/RGMII/clock wrappers,
MDIO IOBUF, board assembly or generated IP. Local Vivado results cover a
hardware implementation, but do not replace those missing functional tests.

Documentation checks for this update cover source inventory counts, relative
links, Mermaid syntax, XCI JSON parsing, Tcl completeness, synthesis-file-list
parity with the Makefile, and source-file hashes after the incoming GEM edits.

XSim targets are available in `sim/Makefile` and currently reference
`/tools/Xilinx/2026.1/Vivado/settings64.sh`. They were not rerun for this
inventory. Existing local XSim databases and simulator binaries are build
artifacts and are excluded from Git.
