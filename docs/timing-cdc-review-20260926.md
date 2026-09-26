# Routed timing and CDC review — 2026-09-26

The subsequent [rebuild and board deployment](verification.md#2026-09-26-cpu-tx-metadata-and-dma-pipeline-board-deployment)
removed the CPU TX override crossing. This document preserves the preceding
image's findings and remaining interface/mailbox review work.

## Result and scope

**Timing passes the current constraints; CDC and board-interface sign-off is
not complete.** This review regenerated reports from the routed management 1.1
checkpoint used for the board image at the time of this audit. It did not change RTL, timing
constraints, firmware, the board image or CDC waivers.

Checkpoint:
`build/ip_refactor/management_1_1_impl/project/kr260_switch.runs/impl_1/kr260_top_routed.dcp`

SHA-256: `862a10bd2fcd8acb0f52c0a2e9d82b347e915ff8c928f7c47c21a94776807463`.
Tool: Vivado 2026.1, device `xck26-sfvc784-2LV-c`.
Reports: `build/ip_refactor/timing_cdc_review_20260926/final/`.

This supersedes the **report counts** in the September 19/20 historical
[CDC review](cdc-review.md), including its old zero-critical statement.
A report row is a structural finding, not necessarily an independent defect.
No critical rows have been blanket-waived.

## Timing results

Overall setup WNS **+0.018 ns**, hold WHS **+0.010 ns**; setup/hold total
negative slack and failing-endpoint counts are zero. There are no unclocked
registers or unconstrained internal maximum-delay endpoints. Pulse-width
checks meet their constraints, with minimum slack 0.000 ns.

| Physical interface | Setup slack (ns) | Hold slack (ns) |
| --- | ---: | ---: |
| PL0 TX data/control to forwarded TX clock | 0.018 | 0.122 |
| PL1 TX data/control to forwarded TX clock | 0.053 | 0.105 |
| PL0 external RX data/control to IDDRE1 | 0.461 | 0.422 |
| PL1 external RX data/control to IDDRE1 | 0.468 | 0.458 |

The RX figures above are specifically external input paths; the RX clock
**domain's** worst hold slack is 0.101 ns for each port, on other paths.
The worst setup path is PL0 TX bit 0 from
`u_pl/u_rgmii0/g_txd_oddr[0].u_oddre1/CLK` to `pl0_rgmii_txd[0]`.
Its reported data-path delay is 1.729 ns and output delay is 3.250 ns.

Selected intra-domain setup/hold slack, distinct from the external TX checks:

| Domain | Setup (ns) | Hold (ns) |
| --- | ---: | ---: |
| Fabric, 100 MHz | 1.943 | 0.010 |
| AXI-Lite / MAC stream, 142.857 MHz | 1.984 | 0.017 |
| GEM0 RX / TX | 1.949 / 1.724 | 0.041 / 0.064 |
| GEM1 RX / TX | 1.803 / 2.018 | 0.017 / 0.041 |
| PL0 / PL1 GMII, 125 MHz | 3.081 / 3.234 | 0.019 / 0.012 |
| SFP PCS, 125 MHz | 2.041 | 0.016 |

### RGMII budget needs physical qualification

[The constraints](../constraints/kr260_rgmii_io.xdc) assume a nominal PHY TX
clock delay of 1.75 ns and use output delays 3.250/0.850 ns. RX input delays
are 2.800/1.200 ns. The local [DP83867 datasheet](dp83867cs.pdf), section 6.10,
lists both clock/data skew and internal-delay setup/hold requirements; its
no-internal-delay and internal-delay conditions must not be conflated.

The XDC does not explicitly itemize carrier/SOM trace skew or programmed PHY
delay tolerance. Its nominal-delay derivation needs a documented worst-case
budget including those terms and readback of actual PHY configuration.
**18 ps of remaining PL0 setup margin is small**, but it is not evidence that
the earlier packet loss was caused by timing. That loss stopped after
reconnection without a design change. Do not tune delay codes solely to make
a report green, or loosen the I/O requirements without physical justification.

## CDC inventory and disposition

| Rule | Rows | Review disposition |
| --- | ---: | --- |
| CDC-1 | 2,632 | All originate at management `stats_index_reg` and reach statistics counter update/clear logic. Conditional bundled-data protocol, discussed below. |
| CDC-3 | 110 | Recognized single-bit synchronizers; protocol/reset assumptions still apply. |
| CDC-5 | 1 | CPU TX override value: unresolved multi-bit transfer and missing second-stage ASYNC_REG. |
| CDC-6 | 25 | 18 MAC Gray-pointer groups, 2 GEM permit counters, 4 independent port-control vectors, 1 vendor AXI group. |
| CDC-9 | 5 | Recognized asynchronous-reset synchronizers. |
| CDC-10 | 13 | Combinational statistics bank-request decode before request synchronizers. |
| CDC-12 | 8 | Statistics acknowledgment mux combines eight source clock domains before one synchronizer. |
| CDC-15 | 1,878 | 800 statistics paths, 192 legacy MAC snapshot paths, 213 MAC descriptor paths, 655 XPM FIFO paths, 18 vendor GTH paths. |

### Statistics mailbox: conditionally justified, not 2,632 separate bugs

Reviewed [CSR sequencing](../rtl/board/rx_diag_regs.sv),
[bank routing](../ip_repo/management/hdl/switch_stats_router.sv) and
[counter capture](../rtl/stats/stats_bank.sv):

1. The selector can change only with request low, synchronized acknowledgment
   low and no pending read/response. A selector write and new DATA read cannot
   both change the selector and assert the request on the same CSR cycle.
2. The selected request is synchronized through two destination flops; capture
   occurs on a subsequent edge. The selector stays fixed through capture.
3. The bank registers its value and acknowledgment together. The CSR captures
   the held value only after acknowledgment crosses its two-stage synchronizer.
4. The request then falls. The selector stays locked until synchronized
   acknowledgment falls. A timeout returns a sentinel without abandoning the
   pending request/selector, so firmware can retry that same transaction.

Thus the CDC-1 selector is not intended to be sampled as a freely changing
bus. CDC-10 decode inputs do not change concurrently during an ordinary
request, and the CDC-12 mux selects a fixed bank throughout its transaction.
The applicable clock-pair datapath bounds remain active. Representative worst
routed delays are 5.395 ns for selector-to-counter logic and 4.432 ns for
returned statistics data, within the 7 ns constraint and normal handshake
settling intervals. These are not generic permissions for arbitrary buses.

The argument requires inactive banks to have released acknowledgment, a held
selector, and coordinated reset/recovery. Independent bank resets, stopped
clocks and rapid/adversarial CSR access remain explicit validation obligations.
A future constraint/waiver should name this protocol and exact endpoints;
registering one-hot requests and synchronizing acknowledgments per bank would
make the implementation easier for tools to recognize, but is not required
merely to reduce the number of report rows.

### CPU TX override: remains a real sign-off blocker

[ctrl_value_xdomain](../rtl/common/ctrl_value_xdomain.sv) launches the value
and a toggle together, synchronizes them independently and has no return
acknowledgment. Only `value_sync1` carries ASYNC_REG; `value_sync2` does not.
Adding that attribute alone would not establish coherent data/event pairing,
prevent closely spaced writes from coalescing, or define independent-reset
behavior. The routed value path meets timing (worst sampled delay 0.903 ns),
which does not establish correctness of this protocol.

Use a held-data request/acknowledgment transfer or asynchronous FIFO, with
explicit busy/acceptance and reset behavior. Firmware must serialize override
arming and descriptor submission as one operation, including failure cleanup.
This remains relevant before enabling STP; STP is currently disabled. There is
no evidence tying this dormant control path to the PL0 ping losses.

### Gray pointers and FIFOs

MAC data-read pointer publication advances one word per source clock; MAC
descriptor pointers and GEM permit counters advance by at most one. Their
first/second stages carry ASYNC_REG. Custom paths retain 7/8 ns clock-pair
maximum-delay bounds. The audit found 138 first-stage custom Gray endpoints;
the worst reported datapath delay is 1.511 ns (minimum slack 5.535 ns).
Explicit custom bus-skew assertions and per-instance
checks would be preferable to relying on broad clock-pair constraints during
future hierarchy changes.

The 26 **vendor XPM FIFO bus-skew constraints** pass, with minimum slack
5.748 ns. This includes the CPU RX-tag FIFO; it is no longer an uninspected
addition to the routed report. FIFO structural CDC correctness does not prove
RX tags stay aligned with DMA completions or handle FIFO-full/error recovery.
The synthesis `async_fifo` uses the write-side reset only, unlike the portable
model's independent resets. Clock-stop and asymmetric reset testing remains
necessary. FIFO36E2 internal crossings do not appear as ordinary fabric CDC
rows, so elastic-buffer reset/underflow behavior needs separate validation.

The four port-control CDC-6 vectors contain independent per-port levels or
toggles, not atomic multi-bit words. Firmware pacing and waiting for flush
completion are part of their contract; rapid toggles can still coalesce.

## Missing constraints and methodology findings

The seven inputs and eleven outputs lacking ordinary I/O delays are not all
missing Ethernet datapath timing:

| Pins | Status / action |
| --- | --- |
| `pl0_mdio`, `pl1_mdio` inputs | Genuine external timing-model gap. |
| Both MDC and MDIO outputs | Model MDIO data/turnaround relative to generated MDC, including supported programmable divider values. |
| Two SFP LED outputs | Non-timing-critical indicators; document an explicit exception. |
| SFP sideband and IIC inputs/outputs | Existing intentional false paths; input synchronization/core behavior and slow-interface timing still need their own justification. |
| Two RGMII forwarded TX clocks | Clocks, already used as output timing references; not missing TX data constraints. |

The MDIO master samples MDIO directly on a clock-enable-qualified system-clock
edge while raising MDC; it is not a generic two-flop asynchronous input.
At divider 35, the half-period is 252 ns (36 x 7 ns). The local PHY datasheet
section 6.8 specifies 0–10 ns MDC-to-MDIO output delay and 10 ns input setup/hold.
Use those requirements, board delays and actual sampling phase to construct
the constraint; do not blanket-false-path MDIO or invent a zero input delay.
`report_cdc` explicitly skips input ports without a defined input clock/delay,
so its absence of MDIO findings is not clearance.

Other findings:

- Three LUT-driven asynchronous-reset warnings: one local GTH wrapper combines
  TX/RX done, and two are in generated GTH reset/calibration logic. Review
  startup/clock-loss behavior and independent done transitions; synchronized
  release alone does not prove a combinational assertion source glitch-free.
- Two duplicate 25 MHz reference-clock definitions override vendor definitions
  with the same 40 ns period. No multiple-clock endpoints are reported, but
  clock ownership should be made explicit when packaging the physical shells.
- 54 references to auto-derived clock names are hierarchy-sensitive. Prefer
  clocks obtained from clock-generator pins and fail on missing objects.
- Several broad clock-pair exceptions have no remaining paths, or are
  overridden by vendor FIFO exceptions. One vendor reset exception has an
  invalid endpoint. Preserve vendor ownership and inspect actual coverage;
  these are not evidence that a whole clock pair may be safely false-pathed.
- The SFP MMCM has an unlocated-global-clock advisory. The present route passes;
  placement/clock-route intent should be scoped with its future IP package.

## Recommended closure order

1. Correct the CPU override transfer and its firmware transaction boundary
   before STP is enabled; test back-to-back requests and independent resets.
2. Close the MDIO timing model and RGMII worst-case board/PHY budget. Keep both
   setup and hold checks on both DDR edges; improve margin if required.
3. Add per-crossing checks for selector/data bounds and custom Gray skew,
   documenting the statistics protocol instead of blanket waivers.
4. Exercise reset/clock-stop recovery, FIFO/tag alignment and repeated flushes
   with vendor primitive models, then re-run routed reports after changes.
5. Clean up clock ownership and scoped physical constraints during IP migration.

## Reproduce

```sh
/tools/Xilinx/2026.1/Vivado/bin/vivado -mode batch \
  -source ip_repo/review_timing_cdc.tcl \
  -tclargs \
  build/ip_refactor/management_1_1_impl/project/kr260_switch.runs/impl_1/kr260_top_routed.dcp \
  build/ip_refactor/timing_cdc_review_20260926/final
```

The script produces timing, CDC, clock-interaction, methodology, exception
coverage/ignored-exception, bus-skew, per-port I/O and custom-crossing reports.
Successful script completion means reports were generated, **not** that CDC
sign-off is complete. No synthesis, PNR, board download or design mutation is
needed to reproduce this review.
