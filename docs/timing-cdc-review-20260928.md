# Routed timing and CDC review — 2026-09-28 UTC

The deployed CPU-interrupt build meets its existing timing constraints, but
**external-interface and reset-recovery sign-off remain open**. This review
uses Vivado 2026.1 and the routed checkpoint from commit `f2b680d`:

`build/cpu_irq/acceptance_2026/project/kr260_switch.runs/impl_1/kr260_top_routed.dcp`

The review ran on September 27 local time / September 28 UTC. It changes audit
coverage and documentation, not RTL, numeric implementation constraints or
the running hardware image. No CDC waivers were added.

## Timing results and limitations

Overall setup WNS is **+0.018 ns**, hold WHS **+0.010 ns**, with zero failing
setup/hold endpoints under the current constraints.

| RGMII interface | Minimum setup slack (ns) | Minimum hold slack (ns) |
| --- | ---: | ---: |
| PL0 TX | 0.018 | 0.122 |
| PL1 TX | 0.053 | 0.105 |
| PL0 RX | 0.459 | 0.419 |
| PL1 RX | 0.468 | 0.458 |

The 18 ps TX margin is relative to a provisional external model. The XDC
derivation uses the PHY's **no-internal-delay** `TskewR` range together with a
nominal programmed internal delay of 1.75 ns. That does not establish the
worst-case budget for the configured internal-delay mode. Rebuild this budget
from that mode's setup/hold requirements, bounded programmed delay, clock duty
cycle, and physical data-versus-clock skew. RX likewise needs its PHY waveform
and physical skew assumptions checked. Do not select a delay code merely
because it makes the existing model pass.
See [TI DP83867CS datasheet, sections 6.8–6.10](https://www.ti.com/lit/ds/symlink/dp83867cs.pdf).

The supplied `docs/xtp688-kria-k26-trace-delay/Kria_K26_Trace_Delay.csv` was
mapped through the installed K26 board pin XML to the project's package pins.
Its readme explicitly includes **package plus SOM trace** delay and excludes
connectors. This vendor reference remains a local, Git-ignored download;
obtain XTP688 through the AMD guidance linked below to reproduce the mapping.
These totals must not simply be added to the current XDC: package
timing already belongs to the Vivado device model. The inspected routed ports
have empty `PCB_MIN_DELAY` / `PCB_MAX_DELAY` properties; board XML attributes
alone are not evidence that the external path has been constrained. A
trace-only budget requires reconciling the package component and its corners,
then including carrier traces and connectors.
[AMD UG1091 timing-model guidance](https://docs.amd.com/r/en-US/ug1091-carrier-card-design/SOM-I/O-Timing-Model).

For screening only, the combined CSV data-minus-clock extrema are below.
They combine data minimum with clock maximum, and vice versa, across the five
data/control signals. They are **not trace-only delays or approved XDC values**.

| Group | Combined minimum (ns) | Combined maximum (ns) |
| --- | ---: | ---: |
| PL0 TX | -0.05437 | +0.11903 |
| PL0 RX | -0.08077 | +0.08418 |
| PL1 TX | -0.17121 | +0.03398 |
| PL1 RX | -0.10029 | +0.12037 |

Carrier routing data was not present at the time of this review. The SOM file
alone cannot close the physical timing budget; the user confirmed that only
XTP688 is available.

## MDIO: still unconstrained

The six `TIMING-18` warnings are the MDIO inputs and MDC/MDIO outputs on both
ports. `report_cdc` skips inputs without a clock/input-delay model, so its
counts do not qualify the MDIO read path.

At the default divider of 35 and 7 ns control-clock period, MDC has a 252 ns
half-period and 504 ns period. The master changes write data on a falling MDC
transition and samples read data on the system edge that launches rising MDC.
The PHY timing diagram specifies read-data changes following **rising** MDC,
not falling MDC: this sample consumes data from the preceding rising edge.
Read setup therefore uses a full MDC period; read hold must include the
outbound clock and returning data path. Write setup/hold use half-periods.
The PHY specifies 0–10 ns clock-to-data and 10 ns input setup/hold.
[TI timing table and Figure 6-3](https://www.ti.com/lit/ds/symlink/dp83867cs.pdf).

Before adding a generated-clock/clock-enable multicycle model, define and
enforce the supported divider contract. The divider register at offset `0x14`
accepts arbitrary values, including changes while busy; the master does not
latch it at transaction start. A constraint assuming a stable default divider
would not cover all exposed register behavior. Required follow-up:

1. Specify the production minimum divider and stable-during-transfer behavior;
   preserve a deliberate fast-divider option for simulation if needed.
2. Model both write data and output-enable turnaround, and read setup/hold,
   including physical round-trip bounds and pull-up/turnaround behavior.
3. Verify setup/hold multicycle pairing against the actual sample enable, then
   rebuild and qualify MDIO on hardware. Do not hide these paths with false paths.

## CDC inventory and mailbox reasoning

| Rule | Severity | Count |
| --- | --- | ---: |
| CDC-1 | Critical | 2,632 |
| CDC-3 | Info | 144 |
| CDC-6 | Warning | 44 |
| CDC-9 | Info | 5 |
| CDC-11 | Critical | 2 |
| CDC-15 | Warning | 2,028 |

All CDC-1 rows originate in statistics mailbox `source_select` registers.
The selector and request launch together; request crosses two synchronizer
stages before the source captures/clears a selected counter. The selector is
held throughout ownership, including ACK release. Return value and ACK launch
together; ACK crosses two stages before management saves the held value.
A CPU timeout does not cancel the request or release its slot.

| Routed family | Reported paths | Maximum data-path delay (ns) |
| --- | ---: | ---: |
| Selector to counter/value logic | 3,115 | 3.485 |
| Request to first synchronizer stage | 13 | 1.338 |
| Returned value to saved result | 377 | 1.628 |
| ACK to first synchronizer stage | 13 | 1.089 |
| Activity Gray bits to first stage | 52 | 0.698 |

These data paths meet the existing bounds. Selector and return-value flight
times are well below the two-clock handshake latency (at least 14 ns for the
clocks involved). The table reports worst paths per endpoint, not every
possible logical arc. This supports the held-data protocol under normal
operation and stopped/resumed clocks; it does **not** establish coherent
independent resets. Destructive reads interrupted by a source reset still
need a defined recovery contract and fault-injection tests.

The 44 CDC-6 groups comprise 18 MAC pointer vectors, two GEM permit vectors,
13 activity vectors, four port-control vectors, four RGMII speed-mode vectors
and three vendor AXI data vectors. Speed mode is not a Gray code: it relies
on firmware disabling/flushing the port, writing mode while disabled, and
waiting before enabling, plus the longer enable synchronizer in the adapter.
Raw register writes that bypass that sequence are outside this contract.

## Gray audit coverage correction

The old source-name filter reported 138 pointer/permit paths. It missed six
MSBs: synthesis merged each MAC's `rx_desc_wr_gray[4]` and
`tx_desc_wr_gray[3]` launch flop into the equivalent binary MSB flop. This
was an **audit coverage defect**, not evidence of an incorrect Gray encoder.

The audit now enumerates destination registers and requires exactly **144
pointer/permit bits plus 52 activity bits**. Each bit must have `ASYNC_REG`,
a recognized launch register, one source clock, a timed path, nonnegative
constraint slack, and maximum flight time below one source-clock period.
The six merged MSB names are explicitly recognized. A changed inventory or
missing path fails the audit instead of silently shrinking its coverage.
The older family report also rejects empty and potentially truncated results.

The checked run passes all 196 bits. Pointer/permit flight time is at most
1.365 ns (minimum constraint slack 5.681 ns); activity flight time is at most
0.698 ns (minimum constraint slack 6.348 ns).

Validation reran the final audit on the unchanged routed checkpoint, then
injected three failures in memory: removed `ASYNC_REG`, an unsatisfiable
0.001 ns maximum delay, and a false path on one Gray destination. All three
were rejected. Vivado can return a false-pathed path with empty slack, so the
audit explicitly requires numeric slack. No modified checkpoint was saved.

This checks routed coverage and delay bounds. Logical single-step updates,
launch-clock skew, synchronizer behavior and reset coherence remain part of
the CDC contract; the audit is not a blanket waiver or an MTBF proof.

## SmartConnect reset fan-out: unresolved recovery contract

Both CDC-11 endpoints are the first auxiliary-reset synchronizer stage of
`sc_ctl/M_AXI[5].mi_cdc.m_psr` and `M_AXI[8].mi_cdc.m_psr`, for the DMA and
MAC-dump control interfaces. Routed tracing confirms two separate four-stage
`ASYNC_REG` chains, both clocked by the 125 MHz fabric clock and fed from
`rst150` peripheral reset. The first-stage outputs feed their respective
second stages. Separate chains can release on different cycles; their
presence in vendor IP alone does not justify a waiver.
[AMD reset-synchronizer guidance](https://docs.amd.com/r/en-US/ug906-vivado-design-analysis/Asynchronous-Reset-Synchronizer).

More materially, `sc_ctl/aresetn` is driven by the PS/control reset, whereas
DMA, `sc_dma`, and `sc_ddr` reset from the PL0 MMCM-derived fabric reset.
Loss of that MMCM's lock asserts the fabric reset without asserting the
control SmartConnect reset. Thus an in-flight AXI transaction may straddle
a reset of its target. Normal startup/packet tests do not establish recovery
from this event.

Required follow-up is a coordinated reset/transaction-abort contract across
these interfaces, then simulation and hardware fault injection covering
pending reads/writes, stopped clocks, and relock. Confirm that software
timeouts cannot release DMA/dump memory before hardware ownership ends.
Leave both CDC-11 findings open until that evidence exists.

## Reproduction and next closure steps

```sh
/tools/Xilinx/2026.1/Vivado/bin/vivado -mode batch -nolog -nojournal \
  -source ip_repo/review_timing_cdc.tcl \
  -tclargs \
  build/cpu_irq/acceptance_2026/project/kr260_switch.runs/impl_1/kr260_top_routed.dcp \
  build/ip_refactor/timing_cdc_review
```

Local evidence is under `build/ip_refactor/timing_cdc_20260928/`: baseline
and checked audit reports, `som_ports.csv`, routed port/package properties,
and reset/Gray launch tracing. These generated artifacts are ignored by Git.

Closure order: obtain the missing physical/PHY bounds and correct the RGMII
model; define and constrain the supported MDIO timing contract; resolve
coordinated reset recovery; then run a fresh full implementation and hardware
qualification. Passing the current checkpoint audit alone is not full timing
or CDC sign-off.
