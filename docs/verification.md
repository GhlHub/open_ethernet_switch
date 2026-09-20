# Design inventory verification

Date: 2026-09-19. This inventory rebuilt **25 portable testbenches through 23 Icarus
targets**, reran 16 distinct lint targets and ran six XSim targets. The new
IDELAY primitive bench brings the total to 26 distinct testbenches.
Incoming RTL, constraints, IP, build scripts and benches were preserved.
Local implementation artifacts were inspected separately; no synthesis or
implementation build was launched for this inventory.

| Tool | Observed version |
| --- | --- |
| Icarus Verilog | 13.0 stable (`v13_0-dirty`) |
| Verilator | 5.020 |
| Vivado / XSim | 2026.1 |

## Simulation results

All portable targets returned zero and all subtests printed their final pass
markers, with no runtime failure markers. `sim-mdio` runs two benches;
`sim-rx-diag` runs two; `sim-rx-elastic` repeats one bench at five clock offsets.
The MAC-reset bench is also a build dependency of `sim-mdio`, but is executed
only by `sim-mac-reset`. Icarus warnings about `unique` and sensitivity remain.

| Target | Testbench | Observed coverage | Result |
| --- | --- | --- | --- |
| `sim-mac` | [`tb_mac_addr_table.sv`](../tb/tb_mac_addr_table.sv) | Learning, hit/miss, aging, per-port flush, merged back-to-back flushes and relearning | PASS |
| `sim-bufmgr` | [`tb_buf_mgr_core.sv`](../tb/tb_buf_mgr_core.sv) | Unicast, free-list reuse, multi-destination references, zero-mask drop, down-port admission, queue flushing, concurrent release/flush races and all 256 buffers reclaimed | PASS |
| `sim-ingress` | [`tb_ingress_top.sv`](../tb/tb_ingress_top.sv) | Odd-length DDR write, bad-frame drop, two concurrent ingress frames | PASS |
| `sim-egress` | [`tb_egress_top.sv`](../tb/tb_egress_top.sv) | DDR read/stream reconstruction, buffer release, two output ports, continuous output after prefetch and backpressure | PASS |
| `sim-ps-eth` | [`tb_ps_gem_axis_bridge.sv`](../tb/tb_ps_gem_axis_bridge.sv) | RX overflow timing and abort termination, flush/next-frame recovery, TX framing and underflow/drain/flush recovery, 1518-byte line-rate RX/TX and permit Gray monitor | PASS |
| `sim-integ` | [`tb_egress_gem_tx_integration.sv`](../tb/tb_egress_gem_tx_integration.sv) | Buffer manager + DDR egress + GEM TX adapter; even/odd frame lengths buffered completely before GEM reads | PASS |
| `sim-async-fifo` | [`tb_async_fifo.sv`](../tb/tb_async_fifo.sv) | Ordering across clocks, full/empty behavior, rejected writes when full, sustained FIFO traffic | PASS |
| `sim-pl-gmii` | [`tb_pl_gmii_adapters.sv`](../tb/tb_pl_gmii_adapters.sv) | Stream adapter round trips for 27-, 14-, and 100-byte frames; does not instantiate the MAC | PASS |
| `sim-sfp-pcs` | [`tb_sfp_1000base_x_pcs.sv`](../tb/tb_sfp_1000base_x_pcs.sv) | 16-bit parallel self-loopback; negotiation status, sync acquire/loss/recovery, frame/error propagation | PASS |
| `sim-sfp-port` | [`tb_sfp_port_top.sv`](../tb/tb_sfp_port_top.sv) | MAC + PCS + adapters in digital loopback; 73/60-byte frames, 20 x 600-byte recycling stress, MAC Gray-pointer monitors | PASS |
| `sim-cpu-port` | [`tb_cpu_port_top.sv`](../tb/tb_cpu_port_top.sv) | CPU TX into pool, CPU RX from pool, lengths/content and buffer reuse | PASS |
| `sim-mac-fwd` | [`tb_mac_forwarding_top.sv`](../tb/tb_mac_forwarding_top.sv) | Unknown-destination flood, source learning, subsequent targeted hit, short-frame drop | PASS |
| `sim-switch-top` | [`tb_switch_top.sv`](../tb/tb_switch_top.sv) | Assembled switch: 52-byte unknown-destination frame from PS GEM0 reaches CPU egress byte-for-byte; CPU down/flush blocks delivery and re-enable delivers only new traffic | PASS |
| `sim-gth-sim` | [`tb_gth_sfp_sim_model.sv`](../tb/tb_gth_sfp_sim_model.sv) | Behavioral GTH reset/status, ten parallel words with K flags through three-cycle loopback, forced error assertion/clear | PASS |
| `sim-rgmii-sim` | [`tb_rgmii_gmii_sim_model.sv`](../tb/tb_rgmii_gmii_sim_model.sv) | Behavioral RGMII loopback: 20- and 12-byte frames plus error propagation at byte 5 of a 16-byte frame | PASS |
| `sim-pl-clkgen-sim` | [`tb_pl_eth_clk_gen_sim_model.sv`](../tb/tb_pl_eth_clk_gen_sim_model.sv) | Model lock/startup reset release; measured periods 8 ns, 3.334 ns, 10 ns | PASS |
| `sim-mdio` | [`tb_mdio_controller.sv`](../tb/tb_mdio_controller.sv), [`tb_phy_init_seq.sv`](../tb/tb_phy_init_seq.sv) | Clause 22 read/write/status; modeled PHY setup, strap variant, absent/wrong ID, PHY link polling/status changes and deferred CPU START | PASS (both benches) |
| `sim-rx-elastic` | [`tb_rgmii_rx_elastic.sv`](../tb/tb_rgmii_rx_elastic.sv) | Portable FIFO, 0/±500/±3000 ppm: contents/order, gap ≥8, no diagnostic events | PASS (five cases) |
| `sim-rx-diag` | [`tb_rx_diag.sv`](../tb/tb_rx_diag.sv), [`tb_sfp_sideband.sv`](../tb/tb_sfp_sideband.sv) | Sticky flag/W1C, link masks/flush toggles, busy, link events and IRQ; scaled-timer insertion/removal, force-off, retry/lockout and clear | PASS (both benches) |
| `sim-autoneg` | [`tb_autoneg_1000base_x.sv`](../tb/tb_autoneg_1000base_x.sv) | Two cross-wired PCS instances negotiate default abilities, pass frames both directions, lose link and renegotiate after injected RX corruption | PASS |
| `sim-mac-reset` | [`tb_mac_reset_reclock.sv`](../tb/tb_mac_reset_reclock.sv) | Reset assertion/release, TX/RX isolation, short reset pulse and AXI register reset | PASS |
| `sim-mac-adapters` | [`tb_mac_adapters.sv`](../tb/tb_mac_adapters.sv) | RX/TX lengths 1–40 and 63/64/65/1518, backpressure, sustained word-per-cycle and back-to-back frames | PASS |
| `sim-pl-linerate` | [`tb_pl_mac_linerate.sv`](../tb/tb_pl_mac_linerate.sv) | MAC + adapters GMII loopback: 12 × 1518, 24 × 64 and 60 × 100-byte frames; descriptor wrap and inter-frame gaps | PASS |

```bash
make -B -C sim sim-mac sim-bufmgr sim-ingress sim-egress \
    sim-ps-eth sim-integ sim-async-fifo sim-pl-gmii \
    sim-sfp-pcs sim-sfp-port sim-cpu-port sim-mac-fwd \
    sim-switch-top sim-gth-sim sim-rgmii-sim sim-pl-clkgen-sim \
    sim-mdio sim-autoneg sim-mac-reset sim-rx-elastic sim-rx-diag \
    sim-mac-adapters sim-pl-linerate
```

Check final `=== ALL TESTS PASSED ===`, `PASS: errors=0`, or (elastic bench)
`PASS` for every subtest, and reject FAIL/FATAL/ERROR/timeout output. `$finish`
and output-filtering pipelines do not reliably propagate failure through
Make's exit code. An automated runner with explicit failure propagation remains
pending. Plain `make sim` still runs only the MAC-table bench.

## Vendor primitive simulations

The following six XSim targets were freshly run and passed:

| Target | Hardware path tested |
| --- | --- |
| `xsim-async-fifo-xpm` | XPM FIFO ordering/full/empty and reset startup |
| `xsim-ps-eth-xpm` | GEM bridges with XPM, including recovery and 1518-byte RX/TX |
| `xsim-integ-xpm` | Egress/GEM integration with XPM |
| `xsim-pl-gmii-xpm` | MAC stream adapters with XPM |
| `xsim-rx-elastic-hw` | Real FIFO36E2 model, +500 ppm offset |
| `xsim-rgmii-idelay-gate` | [`tb_rgmii_idelay_gate.sv`](../tb/tb_rgmii_idelay_gate.sv): IDELAYE3/IDELAYCTRL reset ordering, RDY synchronization, ≥64 receive-clock hold and re-reset |

```bash
make -C sim xsim-async-fifo-xpm xsim-ps-eth-xpm xsim-integ-xpm \
    xsim-pl-gmii-xpm xsim-rx-elastic-hw xsim-rgmii-idelay-gate
```

These targets define `SYNTHESIS` and link XPM or UNISIM plus `glbl`.
The recipes source `/tools/Xilinx/2026.1/Vivado/settings64.sh`.
The checked-in elastic XSim target selects +500 ppm only. Earlier development
notes report ±3000 ppm and a no-cushion mutation check; those are not counted
as fresh results here.

## Coverage limits

The GEM tests tie each RX/TX clock pair together and use exact nominal ratios;
1518-byte tests do not establish sustained all-port throughput under arbitrary
stalls or drift. The TX permit threshold covers the modeled egress gaps;
status interpretation, malformed frames and reset/clock-stop recovery remain open.

The integrated switch smoke test covers GEM0-to-CPU lookup misses and CPU-port down/flush/re-enable. Its
separate [`axi_mem_bfm.sv`](../tb/axi_mem_bfm.sv) instances use a backdoor copy after the physical write, so they do
not validate a shared PS interconnect, coherency or contention. Learned unicast
is covered in the resolver bench, not end-to-end through all ports.

PCS tests directly loop decoded symbols; the standalone GTH model is not a
serial link test. Auto-negotiation tests share clocks and the same RTL, with
short timers and default abilities. They do not establish interoperability,
link-aware frame admission or complete negotiation policy.

The RGMII pin model omits the physical DDR/IDELAY implementation; the elastic
bench separately exercises the FIFO logic. The clock model free-runs nominal
clocks and does not test reference loss or MMCM calibration. No bench verifies
the complete board top or SFP AXI IIC/module bus. The new primitive bench
checks readiness gating, but does not establish board calibration or stopped-clock recovery.
PHY setup uses a modeled device; sideband tests use scaled timing values.

## Lint results

**12 of 16 distinct targets pass.** The four failures are warning-fatal exits:

| Target | Result |
| --- | --- |
| `lint-pl-gmii` | 29 warnings |
| `lint-sfp-port` | 35 warnings |
| `lint-switch-top` | 60 warnings |
| `lint-mdio` | One WIDTHEXPAND: four-bit `step_q` compared with integer `NSTEPS - 1` in `phy_init_seq` |
| Other 12 targets | PASS, no reported warnings |

The first three retain imported MAC width warnings, the `interrupt` reserved
symbol warning and mixed timescales. Warnings were not suppressed. `lint-integ`
selects the same `egress_top` and is not counted again. No standalone lint
recipes exist for the new diagnostics, sideband or elastic-buffer tops; their
simulation compilation is not a substitute for such checks.

## Local Vivado implementation evidence

The inspected reports are dated 2026-09-19 20:42, from Vivado 2026.1 for
`kr260_top`, `xck26-sfvc784-2LV-c`. A routed checkpoint and bitstream exist.
These figures supersede the earlier +0.019/+0.011 ns snapshots. The inventory
did not independently reproduce a clean build or establish exact source-to-
artifact identity; the fingerprints below identify the artifacts inspected.

| Evidence | Result |
| --- | --- |
| Timing | WNS +0.018 ns, WHS +0.010 ns, TNS/THS zero; all user-specified constraints met |
| Utilization | 25,500 LUTs (21.77%), 33,940 registers (14.49%), 51.5 BRAM tiles (35.76%), 3/4 MMCMs |
| CDC summary | Zero critical, 13 warning and 18 informational clock-pair groups |
| DRC | Two REQP-1935 RAM collision warnings; no errors/critical entries |
| Methodology | 105 findings: 104 warnings, one advisory; includes six TIMING-18 missing-delay findings and one unknown-CDC-logic finding |
| Timing completeness | `check_timing`: seven input ports without input delays, 11 ports without output delays (includes intentionally excepted slow pins); zero unclocked endpoints |
| Hardware | No board link, traffic, firmware or throughput result established |

RGMII input/output timing constraints now exist, and the routed setup margin
is thin. Remaining timing findings and board/PHY assumptions need review;
positive slack and zero critical CDC rows do not constitute hardware sign-off.
See [board integration](board-integration.md) and [CDC review](cdc-review.md).

Reports remain ignored under `build/reports/`:

| File | SHA-256 |
| --- | --- |
| `address_map.txt` | `2344952b30464d761d68927d8d4f1f5d976c502578e1314c10189dd31ce392ac` |
| `impl_cdc_summary.rpt` | `f29eac023b3dcc8019c2c963f8fe0e807255cdfd8c670ed4ced5fd6e4a435e0c` |
| `impl_drc.rpt` | `f92f7938199d17159b95b4fe8023b95dc75b9997c46361a642f9d3015bc893f0` |
| `impl_methodology.rpt` | `e4f0ad26e6292ffc4b4cecd95f1d7594f86f52fa6b7e7d0fb24d11c4c868b91f` |
| `impl_timing_summary.rpt` | `5fc018b310697e2353bedc357ec306e54ef65cc7ea3c98503815439bdb8cabae` |
| `impl_utilization.rpt` | `da10ac2e12f85a310c517c84f0ca5864c5adbe0a963c2b203a7ad478f5635012` |

Bitstream SHA-256 (`build/vivado_kr260/kr260_switch.runs/impl_1/kr260_top.bit`):

```text
eb52ae9958c3c7fc60050149e118111489cb865ff99784b963d13e1217d37428
```

Documentation checks cover source counts and links, Mermaid parsing, XCI JSON,
Tcl completeness, synthesis-file-list parity and preservation of source hashes.
Generated simulator/FPGA products and downloaded vendor PDFs stay out of Git.

The FreeRTOS-LTS submodule is pinned to `0b25dc50bae4cb971c7a459b109e52ab2f01a6b8`
on upstream `202604-LTS`; its initialized nested checkouts are clean. This
validates the dependency reference, not a FreeRTOS firmware build.
