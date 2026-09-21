# Design inventory verification

Inventory date: 2026-09-20. The full regression on 2026-09-19 rebuilt **25 portable testbenches through 23 Icarus
targets**, reran 16 distinct lint targets and ran six XSim targets. The new
IDELAY primitive bench brings the total to 26 distinct testbenches.
Those full-regression results are retained below; they were not rerun for the
board-only delay change. Incoming source is preserved.
Local implementation artifacts were inspected separately; no synthesis or
implementation build was launched for this inventory.

| Tool | Observed version |
| --- | --- |
| Icarus Verilog | 13.0 stable (`v13_0-dirty`) |
| Verilator | 5.020 |
| Vivado / XSim | 2026.1 |

## Checks for the 2026-09-20 update

The sole RTL change since `166c765` sets PL1 RX data/control IDELAY to 750 ps
(previously 1000 ps); PL0 remains 700 ps. Counts remain 63 RTL SystemVerilog
files, 59 logical modules, four packages, 26 benches, three XCI configurations
and four XDC files. The FreeRTOS-LTS pin is unchanged.

A temporary copy of `tb_rgmii_idelay_gate.sv` was run with the DUT override
`RX_DATA_IDELAY_PS=750`, using the same XSim/UNISIM flow as
`xsim-rgmii-idelay-gate`. It passed with `PASS: errors=0`, checking reset order,
RDY gating, the 64-cycle hold and re-reset. The checked-in bench continues to
use the adapter default of 500 ps. This check exercises the new delay setting
but does not validate board skew, electrical margins or the complete board top.

Documentation links/diagrams, source counts, XCI JSON, Tcl completeness and
synthesis-list parity were checked. The local routed reports below were
refreshed; no implementation run was launched for this inventory.

## Simulation results (2026-09-19)

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

The following six XSim targets were run on 2026-09-19 and passed:

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

The inspected reports are dated 2026-09-20 04:18, from Vivado 2026.1 for
`kr260_top`, `xck26-sfvc784-2LV-c`. A routed checkpoint and bitstream exist.
These figures match the previous +0.018/+0.010 ns overall slack and resource
counts; report timestamps and fingerprints have changed. The inventory
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
| `impl_cdc_summary.rpt` | `af1ca62fdeb85fa6e08c16566128688fa38b432aa27bc1e31ea2e6f55529ee0e` |
| `impl_drc.rpt` | `189ec66bdadea8948f559a7dab6bfbcd3931bf51470f4538127d0e03efd17ad5` |
| `impl_methodology.rpt` | `2a2302cd13f8adbe890255c3658921253eef1f67340c78b9702f1503278091de` |
| `impl_timing_summary.rpt` | `56ecbf276d50c6e8032d2025e40fd22513caf7001efab53878511ca178d479f3` |
| `impl_utilization.rpt` | `33fe251bc3caecdd71ca3403b0d91e9e4b631819157c63420bc9ae732efb1ba3` |

Bitstream SHA-256 (`build/vivado_kr260/kr260_switch.runs/impl_1/kr260_top.bit`):

```text
fe719dbfe3c2ce498995b48d6a1081c1c4c25717ba14821d88ae5bc27dc0fc20
```

Documentation checks cover source counts and links, Mermaid parsing, XCI JSON,
Tcl completeness, synthesis-file-list parity and preservation of source hashes.
Generated simulator/FPGA products and downloaded vendor PDFs stay out of Git.

The FreeRTOS-LTS submodule is pinned to `0b25dc50bae4cb971c7a459b109e52ab2f01a6b8`
on upstream `202604-LTS`; its initialized nested checkouts are clean. This
validates the dependency reference, not a FreeRTOS firmware build.

## Initial R5 firmware implementation (2026-09-20)

The [R5 firmware](../software/r5/README.md) builds against a standalone BSP
generated from the existing board XSA with Vitis 2026.1, using the kernel and
TCP sources from the pinned FreeRTOS-LTS submodule. A complete cross-build
passes without compiler warnings. The ELF audit verifies ARM entry, low ATCM
IRQ/SVC vectors targeting FreeRTOS, no unresolved symbols, and load segments
confined to R5 ATCM and reserved DDR (excluding the fabric pool).

`make -C software/r5 test` passes link-state/flush-guard and DHCP retry timing
tests (including counter wrap), plus a descriptor/register model covering TX
padding, alternating descriptors, RX ring recycling, malformed RX and TX
error/timeout ownership. This is not packet-level DHCP or AXI hardware proof.

`sim-rx-diag` and `sim-mdio` pass all four constituent benches, including the
new read-only SFP PCS status check and PHY polling failure/recovery test.
Vivado `synth_design -rtl` of `kr260_top` completes with zero errors/critical
warnings and 285 warnings. This is elaboration only; the earlier routed
reports and bitstream do not validate the new status-register RTL.

At this build-only stage no firmware had been loaded onto a board; see the
subsequent JTAG results below.

### Regenerated hardware: R5 UART console

The updated board XSA includes UART1 at `0xff010000` on MIO36/MIO37. The
R5 platform was updated from that XSA and rebuilt with UART1 selected for
stdin/stdout; generated `bspconfig.h` confirms both addresses. Firmware now
initializes UART1 to 115200 8N1, no flow control, and mirrors output to the
RAM log. The firmware cross-build and ELF vector/memory audit pass. Physical
serial output was subsequently confirmed during the JTAG bring-up below.

### First live R5 bring-up (2026-09-20)

Hardware server: `10.0.1.109:3121`; UART telnet bridge: `10.0.1.109:2323`.
The repository [boot script](../software/r5/boot_jtag.tcl) completes a volatile
PS reset, A53 FSBL initialization, fabric programming and R5-0 startup in split
mode. R5-1 stays reset and A53-0 stays halted; no flash was written. The
[status script](../software/r5/status_jtag.tcl) samples the running application.

Bring-up fixes: select UART1 in the FSBL BSP as well as the R5 BSP; refresh
FSBL-local `psu_init.c/h` after hardware updates (Vitis retained the old files,
leaving UART1 reset); use a full PS reset before DDR initialization; resolve
the assembly `XFsbl_Exit` ELF symbol numerically for an XSDB hardware breakpoint.
The shared PS MDIO bus identifies DP83867 devices (`2000:a231`) at addresses
4 and **9**, with no response at the previously assumed 8. Firmware now uses 9
for GEM1.

Observed:

- FSBL banner and R5 startup/link/DHCP messages arrive on physical UART1;
  `board_uart_dropped` is zero in the final sample.
- 5024 RTOS ticks and 3925577 free-running timestamp counts advance during
  a 5041 ms JTAG sample. Sequential register reads add skew; this supports
  approximately 1 kHz and 781250 Hz, not a precision frequency measurement.
- Both PS PHYs initialize. GEM1 admits a 1 Gb/s full-duplex link;
  `LINK_STATUS=0x22` enables GEM1 plus virtual CPU port 5. Both PL PHY snapshots
  are `0x208` (initialized, valid, link down); both IDELAY ready bits are set.
  No SFP link is present.
- CPU-port AXI DMA RX buffers contain actual IPv4, ARP and IPv6 network frames.
  MM2S completes a DHCP discover frame; final channel status values are
  `0x0001100a` / `0x00011008`, without DMA error bits.
- Initial DHCP attempts failed with a GEM1 TX underrun. Subsequent ILA captures
  identified the missing PS FIFO clock selection and a spurious underrun on
  the read after EOP. After both fixes, all 314 DHCP discover bytes match the
  fabric input, GEM1 completes with zero status error and no PL underrun/flush.
- R5 acquired `10.0.1.214` through DHCP. Five pings from host `10.0.1.24` on
  `eth1` succeeded with zero loss (0.684–1.834 ms). Before ping, GEM1 counters
  showed four successful TX frames, zero TX underruns and 98 RX frames.
  See [GEM1 debug procedure and evidence](gem1-debug.md).

The board remains running this R5 application. PMU firmware is not loaded in
this JTAG flow. Boot-image packaging, TX recovery/throughput, link transitions,
SFP, DHCP renewal and precise retry timing remain
unverified. Local raw bring-up logs are under ignored `build/r5/`; packet captures
are not source artifacts.


## Four copper ports passing DHCP-address ping (2026-09-20)

Milestone: `20260920-copper_ports_passing_dhcp_ping`. The R5 acquired DHCP
address `10.0.1.214` on GEM1. The same network cable was then moved through
GEM0, PL1 and PL0, with no reboot or configuration changes. Each port responded
at that same address through the fabric CPU port. Connector positions below
use the user's orientation when looking at the Ethernet connectors.

| Connector | Fabric port | Link | Final ping sample | Additional observations |
| --- | --- | --- | --- | --- |
| Right lower | GEM1 (1) | 1 Gb/s full duplex | 5/5, zero loss | DHCP acquisition on UART; zero GEM TX underruns |
| Right upper | GEM0 (0) | 1 Gb/s full duplex | 15/15, zero loss | TX/RX counters advance; zero GEM TX underruns |
| Left lower | PL1 (3) | 1 Gb/s full duplex | 20/20, zero loss | PHY status `0x3a8`; no PL RX overflow/underrun flags |
| Left upper | PL0 (2) | 1 Gb/s full duplex | 20/20, zero loss | PHY status `0x3a8`; no PL RX overflow/underrun flags |

Host probes used `eth1` at `10.0.1.24`. GEM0 and PL1 initially lost four
probes each; subsequent samples above were clean. PL0's 20-ping sample had
0.296–2.400 ms round-trip times. R5 remained running and the DMA status showed
no channel errors. The board was left with the cable on PL0.

These observations establish basic bidirectional connectivity on all four
copper ports using the DHCP-assigned address. Fresh DHCP acquisition on each
port was not independently captured, and the move tests do not establish
lossless handover, lease renewal, sustained throughput, simultaneous multiport
forwarding or recovery under faults. SFP remains untested.

The tested image includes the GEM FIFO fixes and two ILAs described in
[GEM1 debugging](gem1-debug.md). It also uses the debug-only PL0 input-delay
adjustment to 900 ps; the ordinary RTL still specifies 700 ps. PL0's result
therefore validates this debug image, not an independently rebuilt normal
image. Final debug-image setup/hold slack is +0.018/+0.010 ns under existing
constraints; remaining timing/CDC review still applies.

Raw logs are local ignored files under `build/gem1_debug/`: `final/`,
`status_port_move.log`, `gem0_port_move.log`, `ping_port_move.log`,
`status_left_lower.log`, `ping_left_lower_settled.log`,
`status_left_upper.log` and `ping_left_upper.log`.


## SFP copper-module bring-up (2026-09-20)

The Ipolex ASF-GE-T works with the 1G 1000BASE-X path after GTH RXCTRL mapping,
TX-derived clock startup, coherent word packing, hardware AN timers, clock
correction, shortened-preamble RX, restart configuration, TX alignment and
idle-disparity fixes. Five new portable benches bring the inventory to 30
portable benches plus one XSim bench. The five focused tests and the eight
PCS phase/alignment cases pass, as do SFP port, two-peer AN and switch tests.
Old RTL reproduces failures in the mapping, gearbox, zero-configuration,
shortened-preamble, TX-alignment and idle-selection regressions. This was a
focused regression, not a fresh run of every unrelated target.

The final instrumented image meets setup/hold at +0.018/+0.012 ns with the
existing constraints and PL0's 900 ps debug override. Two fresh JTAG boots
acquired `10.0.1.214` through the SFP. Settled traffic passed 60/60 small pings
and 30/30 full-MTU pings (1472-byte ICMP payload, no fragmentation). The second
boot also passed 30/30 full-MTU pings but lost ten early small pings before
49 consecutive replies. Initial loss, one RX-error counter increment reported
on the managed switch, and one KR260 RX FCS/error count in the first run
remain unresolved. The second run ended with zero KR260 RX errors/overflow
across 653 accepted frames. These results establish basic connectivity, not
reliable cold startup, a throughput rating or full PCS conformance.

See [SFP investigation](sfp-debug.md) for causes, probes, evidence locations,
and the earlier image's unresolved restart loop. No flash was written.


## All ports passing DHCP and ping milestone (2026-09-20)

Check-in label: `20260920-all_ports_passing_dhcp_ping`.

| Physical connector | Fabric interface | Hardware result |
| --- | --- | --- |
| Right lower RJ45 | PS GEM1 | DHCP address and ping verified in the copper milestone |
| Right upper RJ45 | PS GEM0 | Same DHCP address remained reachable after cable move |
| Left lower RJ45 | PL1 RGMII | Same DHCP address remained reachable after cable move |
| Left upper RJ45 | PL0 RGMII | Same DHCP address remained reachable after cable move |
| SFP cage with Ipolex ASF-GE-T | PL 1000BASE-X | DHCP acquired on two boots; settled small/full-MTU ping passed |

All ports use the fabric's virtual CPU port and the R5 FreeRTOS network stack
at `10.0.1.214`. Copper results were obtained on the earlier copper debug
image; SFP results use the updated SFP debug image. This is accumulated
per-port evidence, not a simultaneous five-port test or a rerun of the four
copper connectors on the final SFP image.

After the SFP tests, the operator confirmed that the managed switch RX-error
counter had not increased beyond 803 since the previous check. No duration
was supplied, so this confirms counter stability over that observation
interval rather than a quantified error-free soak test. The earlier 802→803
increment and startup ping losses remain recorded above. The milestone marks
basic DHCP/ping connectivity across all five physical ports; throughput,
startup reliability and fault-recovery validation remain pending.

## Post-milestone intermittent-loss investigation

The SFP uplink and right-upper GEM0 endpoint `10.0.1.140` were active together.
ILA captured incorrect payload bytes accompanied by GTH disparity and invalid-code
flags before the PCS. The Wizard's AUTO mode had selected DFE; the source XCI
now explicitly selects LPM. Its generated primitive differences were applied
to the debug checkpoint, with unchanged +0.018/+0.012 ns setup/hold slack and
successful bitstream DRC. The project GTH OOC checkpoint was regenerated too.

LPM boot acquired DHCP automatically. The initial CPU full-MTU test lost
sequences 2–25, then received every remaining packet (276/300 overall).
A subsequent repeated-0x73 full-MTU CPU test passed 300/300.
The forwarded endpoint test also passed 300/300 full-MTU pings when the
test socket accepted replies on either host interface. Interface-bound
endpoint tests were misleading: captures show CRC-valid replies addressed
to the workstation's Wi-Fi MAC for its Ethernet IP. Both host interfaces
share the LAN and allow cross-interface ARP replies.
See [detailed evidence and limitations](sfp-debug.md#intermittent-packet-loss-with-an-attached-endpoint).

After at least 60 seconds without generated pings, simultaneous full-MTU
tests passed another 300/300 to each target (default CPU payload, repeated
0x00 endpoint payload). Settled totals were 600/600 per target. The final
SFP counters showed 5,687 accepted RX frames, zero RX FCS/error counts and
zero overflow; links and R5/DMA status remained healthy. This is a short
functional test, not a throughput or long-duration reliability qualification.

## Ingress exclusion on destination lookup hits (2026-09-21)

The resolver now removes the ingress port from learned destination masks.
A hit containing only that port resolves to a valid zero mask (drop), without
falling back to flooding. The forwarding regression learns a destination
behind each of the six ports and checks a subsequent same-port hit; all six
cases failed before the fix and pass afterward. Existing unknown-destination,
other-port unicast and short-frame checks also pass. Commands:
`make -C sim sim-mac-fwd sim-switch-top`. The full switch smoke test passes.
This change is included in the normal hardware image described below.

## Normal image without debug ILAs (2026-09-21)

Re-synthesized the current RTL (including same-port destination filtering)
and implemented the normal project with the LPM GTH configuration. No ILA
or debug-hub cells remain; the implemented design's debug-core collection
is empty. The optional debug insertion/capture scripts remain available
for future investigations and are not part of the normal build.

The image meets setup/hold at +0.018/+0.010 ns under the current constraints.
It uses 25,459 LUTs, 33,953 registers and 51.5 BRAM tiles. Unlike the prior
instrumented image, it meets timing with the source's PL0/PL1 RX delays of
700/750 ps; no 900 ps PL0 implementation override was applied.
`build/impl_kr260.tcl` now rejects incomplete runs, unexpected debug cores
and negative setup/hold slack.

Loaded `build/vivado_kr260/kr260_switch.runs/impl_1/kr260_top.bit` through
`software/r5/boot_jtag.tcl`. R5 started, DHCP acquired `10.0.1.214`,
and SFP plus GEM0 links came up. This was a volatile JTAG load, without
changing boot flash. Logs are under `build/gem1_debug/no_ila/`; implementation
reports are under `build/reports/`.

Simultaneous full-MTU tests passed 300/300 pings to the CPU at
`10.0.1.214` and 300/300 to the GEM0 endpoint at `10.0.1.140`.
Pings used the default Ethernet route without binding the receive socket
to an interface. Final SFP counters: 1,617 accepted RX frames, zero RX
FCS/error counts, zero overflow and 785 TX frames. PCS_STATUS=7,
LINK_STATUS=0x31, R5 timers advanced normally and DMA reported no errors.
The board is left running this image without debug instrumentation.
The other three copper ports were not re-tested in this load.

## R5 data cache with non-cacheable DMA storage (2026-09-21)

Application DDR `0x20000000–0x21ff7fff` retains the BSP's normal write-back
cacheable mapping. The final 32 KiB, `0x21ff8000–0x21ffffff`, is reserved
for all RX/TX descriptors and bounce buffers in `.dma_nocache`, overridden
by a higher-priority MPU region as normal, shareable, non-cacheable and
execute-never. Peripheral mappings remain non-cacheable. Driver state,
FreeRTOS heap and stacks remain cacheable; no cached application buffer is
handed directly to DMA. DMA storage is explicitly cleared after the DMA
reset because its linker section is NOLOAD and outside startup BSS.

`make -C software/r5 -j8 all test` passed: firmware build, ELF/vector audit,
DMA-region placement/alignment checks, link/DHCP policy tests, and DMA
padding, ring-wrap, descriptor rotation and error/timeout ownership tests.
Hardware startup reads back CP15 MPU configuration and asserts MPU/cache
enable. UART reported `SCTLR=00E5187D`, MPU region 10, attributes
`0000130C`, and the expected 32 KiB address range.

Loaded via JTAG using the existing FPGA image without ILAs. DHCP acquired
`10.0.1.214`. Initial 10/10 small pings passed. Concurrent tests passed
1,000/1,000 full-MTU pings (1472-byte payload, repeated A55A) and 1,000/1,000
short pings (57-byte payload, repeated 73) to the CPU, plus 300/300 full-MTU
pings to GEM0 endpoint `10.0.1.140`. CPU traffic repeatedly reuses both
TX descriptors and all 16 RX descriptors. DMA statuses remained
`0x1100a/0x11008`, PCS=7, links=0x31. SFP counters showed 3,435 accepted
RX frames, zero RX errors and zero overflow.

Evidence is in `build/gem1_debug/cache/`. These tests validate basic cache
policy and repeated DMA ownership transfers, not maximum throughput or
long-duration reliability. PSU JTAG reads of cacheable DDR symbols can now
be stale; the status script warns about this. Hardware registers and DMA
storage remain readable without cache maintenance.

A second JTAG boot again reported the expected MPU/cache settings and acquired
the same DHCP address. Its 300/300 full-MTU pings with repeated 0x00 payload
passed, and DMA status remained healthy. The board is left running the
cache-enabled firmware; persistent boot flash was not changed.

The descriptor and packet-buffer cache policy remains a future review item.
The current non-cacheable DMA region is the initial functional baseline.
These passing tests do not select an optimal policy; compare CPU cost and
throughput before considering cached payloads or descriptors, and validate
cache maintenance at every DMA ownership transition.
