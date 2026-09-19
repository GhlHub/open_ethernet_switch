# Design inventory verification

Date: 2026-09-19. This inventory rebuilt **23 testbenches through 21 Icarus
targets**, reran 16 distinct lint targets and ran five vendor-FIFO XSim targets.
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
| `sim-mac` | [`tb_mac_addr_table.sv`](../tb/tb_mac_addr_table.sv) | Learn two addresses, hit/miss masks, aging expiration | PASS |
| `sim-bufmgr` | [`tb_buf_mgr_core.sv`](../tb/tb_buf_mgr_core.sv) | Unicast, free-list reuse, multi-destination references, zero-mask drop, concurrent requests | PASS |
| `sim-ingress` | [`tb_ingress_top.sv`](../tb/tb_ingress_top.sv) | Odd-length DDR write, bad-frame drop, two concurrent ingress frames | PASS |
| `sim-egress` | [`tb_egress_top.sv`](../tb/tb_egress_top.sv) | DDR read/stream reconstruction, buffer release, two output ports | PASS |
| `sim-ps-eth` | [`tb_ps_gem_axis_bridge.sv`](../tb/tb_ps_gem_axis_bridge.sv) | RX overflow timing and abort termination, flush/next-frame recovery, TX framing and underflow/drain/flush recovery, 1518-byte line-rate RX/TX and permit Gray monitor | PASS |
| `sim-integ` | [`tb_egress_gem_tx_integration.sv`](../tb/tb_egress_gem_tx_integration.sv) | Buffer manager + DDR egress + GEM TX adapter; even/odd frame lengths buffered completely before GEM reads | PASS |
| `sim-async-fifo` | [`tb_async_fifo.sv`](../tb/tb_async_fifo.sv) | Ordering across clocks, full/empty behavior, rejected writes when full, sustained FIFO traffic | PASS |
| `sim-pl-gmii` | [`tb_pl_gmii_adapters.sv`](../tb/tb_pl_gmii_adapters.sv) | Stream adapter round trips for 27-, 14-, and 100-byte frames; does not instantiate the MAC | PASS |
| `sim-sfp-pcs` | [`tb_sfp_1000base_x_pcs.sv`](../tb/tb_sfp_1000base_x_pcs.sv) | 16-bit parallel self-loopback; negotiation status, sync acquire/loss/recovery, frame/error propagation | PASS |
| `sim-sfp-port` | [`tb_sfp_port_top.sv`](../tb/tb_sfp_port_top.sv) | MAC + PCS + adapters in digital loopback; 73/60-byte frames, 20 x 600-byte recycling stress, MAC Gray-pointer monitors | PASS |
| `sim-cpu-port` | [`tb_cpu_port_top.sv`](../tb/tb_cpu_port_top.sv) | CPU TX into pool, CPU RX from pool, lengths/content and buffer reuse | PASS |
| `sim-mac-fwd` | [`tb_mac_forwarding_top.sv`](../tb/tb_mac_forwarding_top.sv) | Unknown-destination flood, source learning, subsequent targeted hit, short-frame drop | PASS |
| `sim-switch-top` | [`tb_switch_top.sv`](../tb/tb_switch_top.sv) | Assembled switch: 52-byte unknown-destination frame from PS GEM0 reaches CPU egress byte-for-byte | PASS |
| `sim-gth-sim` | [`tb_gth_sfp_sim_model.sv`](../tb/tb_gth_sfp_sim_model.sv) | Behavioral GTH reset/status, ten parallel words with K flags through three-cycle loopback, forced error assertion/clear | PASS |
| `sim-rgmii-sim` | [`tb_rgmii_gmii_sim_model.sv`](../tb/tb_rgmii_gmii_sim_model.sv) | Behavioral RGMII loopback: 20- and 12-byte frames plus error propagation at byte 5 of a 16-byte frame | PASS |
| `sim-pl-clkgen-sim` | [`tb_pl_eth_clk_gen_sim_model.sv`](../tb/tb_pl_eth_clk_gen_sim_model.sv) | Model lock/startup reset release; measured periods 8 ns, 3.334 ns, 16 ns | PASS |
| `sim-mdio` | [`tb_mdio_controller.sv`](../tb/tb_mdio_controller.sv), [`tb_phy_init_seq.sv`](../tb/tb_phy_init_seq.sv) | Clause 22 read/write/status; modeled PHY setup, strap variant, absent/wrong ID and CPU hold-off | PASS (both benches) |
| `sim-rx-elastic` | [`tb_rgmii_rx_elastic.sv`](../tb/tb_rgmii_rx_elastic.sv) | Portable FIFO, 0/±500/±3000 ppm: contents/order, gap ≥8, no diagnostic events | PASS (five cases) |
| `sim-rx-diag` | [`tb_rx_diag.sv`](../tb/tb_rx_diag.sv), [`tb_sfp_sideband.sv`](../tb/tb_sfp_sideband.sv) | Sticky flag/W1C across clocks; scaled-timer insertion/removal, force-off, retry/lockout and clear | PASS (both benches) |
| `sim-autoneg` | [`tb_autoneg_1000base_x.sv`](../tb/tb_autoneg_1000base_x.sv) | Two cross-wired PCS instances negotiate default abilities, pass frames both directions, lose link and renegotiate after injected RX corruption | PASS |
| `sim-mac-reset` | [`tb_mac_reset_reclock.sv`](../tb/tb_mac_reset_reclock.sv) | Reset assertion/release, TX/RX isolation, short reset pulse and AXI register reset | PASS |

```bash
make -B -C sim sim-mac sim-bufmgr sim-ingress sim-egress \
    sim-ps-eth sim-integ sim-async-fifo sim-pl-gmii \
    sim-sfp-pcs sim-sfp-port sim-cpu-port sim-mac-fwd \
    sim-switch-top sim-gth-sim sim-rgmii-sim sim-pl-clkgen-sim \
    sim-mdio sim-autoneg sim-mac-reset sim-rx-elastic sim-rx-diag
```

Check final `=== ALL TESTS PASSED ===`, `PASS: errors=0`, or (elastic bench)
`PASS` for every subtest, and reject FAIL/FATAL/ERROR/timeout output. `$finish`
and output-filtering pipelines do not reliably propagate failure through
Make's exit code. An automated runner with explicit failure propagation remains
pending. Plain `make sim` still runs only the MAC-table bench.

## Vendor FIFO simulations

The following five XSim targets were freshly run and passed:

| Target | Hardware path tested |
| --- | --- |
| `xsim-async-fifo-xpm` | XPM FIFO ordering/full/empty and reset startup |
| `xsim-ps-eth-xpm` | GEM bridges with XPM, including recovery and 1518-byte RX/TX |
| `xsim-integ-xpm` | Egress/GEM integration with XPM |
| `xsim-pl-gmii-xpm` | MAC stream adapters with XPM |
| `xsim-rx-elastic-hw` | Real FIFO36E2 model, +500 ppm offset |

```bash
make -C sim xsim-async-fifo-xpm xsim-ps-eth-xpm xsim-integ-xpm \
    xsim-pl-gmii-xpm xsim-rx-elastic-hw
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

The integrated switch smoke test covers one GEM0-to-CPU lookup miss. Its
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
the complete board top, IDELAY calibration readiness or SFP AXI IIC/module bus.
PHY setup uses a modeled device; sideband tests use scaled timing values.

## Lint results

**12 of 16 distinct targets pass.** The four failures are warning-fatal exits:

| Target | Result |
| --- | --- |
| `lint-pl-gmii` | 31 warnings |
| `lint-sfp-port` | 37 warnings |
| `lint-switch-top` | 61 warnings |
| `lint-mdio` | One WIDTHEXPAND: four-bit `step_q` compared with integer `NSTEPS - 1` in `phy_init_seq` |
| Other 12 targets | PASS, no reported warnings |

The first three retain imported MAC width warnings, the `interrupt` reserved
symbol warning and mixed timescales. Warnings were not suppressed. `lint-integ`
selects the same `egress_top` and is not counted again. No standalone lint
recipes exist for the new diagnostics, sideband or elastic-buffer tops; their
simulation compilation is not a substitute for such checks.

## Local Vivado implementation evidence

The inspected reports are dated 2026-09-19 13:42, from Vivado 2026.1 for
`kr260_top`, `xck26-sfvc784-2LV-c`. A routed checkpoint and bitstream exist.
These figures supersede the earlier +0.726/+0.671 ns snapshots. The inventory
did not independently reproduce a clean build or establish exact source-to-
artifact identity; the fingerprints below identify the artifacts inspected.

| Evidence | Result |
| --- | --- |
| Timing | WNS +0.019 ns, WHS +0.011 ns, TNS/THS zero; all user-specified constraints met |
| Utilization | 24,264 LUTs (20.72%), 31,852 registers (13.60%), 51.5 BRAM tiles (35.76%), 3/4 MMCMs |
| CDC summary | Zero critical, 13 warning and 18 informational clock-pair groups |
| DRC | Two REQP-1935 RAM collision warnings; no errors/critical entries |
| Methodology | 90 findings: 89 warnings, one advisory; includes six TIMING-18 missing-delay findings and one unknown-CDC-logic finding |
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
| `impl_cdc_summary.rpt` | `92b48a491de7b7453a2a9d08e080fad7362ef9665947faf12f6bf6609c372c3d` |
| `impl_drc.rpt` | `b2c2cd89a101e3099865456e8c2a6adb99c9a1320f34b0cd7c1520db96fd3111` |
| `impl_methodology.rpt` | `30ddba77d6cd51eb342f270547333519dee689eba6488f557317c45e74ae4b95` |
| `impl_timing_summary.rpt` | `5ef75eda3bed992b9d9f98e9b48e0671a33a3b2841f19457ef1c0002229f01f2` |
| `impl_utilization.rpt` | `a18d6926b96ecbb56a4f38e9dfb8b9f85b8f3b145d4fabc00b2ef8f7654a812a` |

Bitstream SHA-256 (`build/vivado_kr260/kr260_switch.runs/impl_1/kr260_top.bit`):

```text
2e269a4312a7da54a38ab94ff8319fb7d659f271984c5b01e1bb6162db7a858b
```

Documentation checks cover source counts and links, Mermaid parsing, XCI JSON,
Tcl completeness, synthesis-file-list parity and preservation of source hashes.
Generated simulator/FPGA products and downloaded vendor PDFs stay out of Git.
