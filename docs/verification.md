# Design inventory verification

## 2026-09-25 independent IP verification

Added package-owned `tests.json` manifests and a shared isolated runner.
Each IP public top is elaborated separately. Behavioral cases consume that
package's manifest sources, or its audited catalog snapshot, with explicit
external test-support dependencies. The GEM multirate bench now also runs
through the public `switch_gem_port` wrapper.

- All 19 cases passed against native RTL and the existing catalog snapshots.
- A fresh Vivado catalog was generated at
  `build/ip_refactor/ip_suite_catalog`; integrity and expanded metadata audits
  passed, and all 19 cases passed using that fresh catalog. Packaging retains existing warnings about SystemVerilog tops,
  unspecified clock frequencies, clocks without associated buses and missing
  product-guide files; this is not a warning-free packaging claim.
- All four native whole-switch optional-counter comparisons passed again:
  29,922 sampled clock events and 114 outputs per configuration.
- The deployed production BD audit passed unchanged register-map, catalog,
  packet/control/DDR/GEM/IRQ wiring checks.
- Deliberately corrupted temporary catalogs were rejected for wrong version,
  crossed stream mapping, wrong stream width, missing clock association,
  escaping source path and stale RTL.

The runner rejects simulator failure messages even when legacy benches exit
zero, requires a success marker, imposes per-command timeouts and writes a
completion-marked JSON report. Logs are in `build/ip_refactor/ip_tests/`.
See [coverage and commands](../ip_repo/README.md#independent-ip-regression-suites).
This change affects verification tooling and testbench selection only;
production RTL and firmware are unchanged from the board-tested milestone.
A randomized concurrent six-port scoreboard and full physical CDC/timing
sign-off remain outstanding.


## 2026-09-25 production catalog board acceptance

Loaded the production catalog bitstream identified below through hw_server
at `10.0.1.107:3121`, with matching `STATS_DDR=1`, `STATS_DEBUG=1` R5 firmware.
The ELF memory/DMA-region audit passed. UART confirmed cache enabled,
statistics capabilities `0x53540107`, saved microSD settings loaded and STP
disabled. GEM1 (right lower, uplink) and PL0 (left upper, endpoint) linked
at 1000 Mb/s. DHCP acquired `10.0.1.104` after the one-minute retry.

| Check | Result |
| --- | --- |
| Initial endpoint ping | 48/100 replies; 52 startup losses |
| Endpoint full-MTU ping before DHCP completed | 200/200 replies |
| R5 normal / full-MTU ping after DHCP | 100/100 and 200/200 replies |
| Concurrent sustained R5 and endpoint full-MTU ping | 1,000/1,000 each |
| One-second statistics HTTP polling during traffic | 55/55 successful reads |
| Statistics/configuration pages and API GETs | HTTP 200 |
| Unauthenticated configuration POST | HTTP 401; settings unchanged |
| SNMP final health | 784 polls, zero late polls, saturation or mailbox timeouts |
| Packet / DDR errors | Zero bad packets and AXI response errors |

Physical-port forwarding does not depend on the management DHCP lease.
Ingress DDR write-data stalls remained exactly two cycles per burst (6,058
bursts and 12,116 stall cycles during measurement), matching the prior image.
Other measured DDR directions had zero data-stall cycles. Sensor readings
were valid with no sensor errors. Browser statistics refreshed successfully;
one statistics-to-configuration navigation timed out, while direct navigation
loaded all settings and controls without JavaScript errors. Its cause remains
unresolved and should be checked again during browser regression.

Initial forwarding loss and DHCP retry remain unexplained. Unconnected
ports, speed combinations and simultaneous all-port load were not retested.
Logs and JSON snapshots are local artifacts under
`build/ip_refactor/production_bd/board_test/`.


## 2026-09-25 production catalog block design

Moved the fabric, two GEM bridges, two PL MACs, SFP MAC/PCS and management
registers into production `system.bd` as catalog IP cells. Physical clocks,
RGMII, MDIO, GTH and sideband logic retain their board hierarchy. The
13-bank statistics decoder is a BD module reference. Counter options are
set on fabric and management together; the firmware register map is unchanged.

Verification before implementation:

- Native equivalence passed all four optional-counter combinations.
- Generated production datapath equivalence passed 29,934 clock samples,
  114 outputs per sample and 1,327 completed snapshots, including all bank
  and slot indices. Packet-content, forwarding, link flush and CPU override
  assertions passed. The fixture releases reset on inactive clock edges
  to eliminate the original stimulus race exposed by BD net aliases.
- Generated-BD audits passed catalog identity, control/DDR/GEM/IRQ wiring,
  clock/reset connections, address windows and unchanged physical-instance
  connections. Catalog source hashes and interface checks passed. Explicit
  zero cache-attribute ties preserve the previous DDR transaction attributes;
  generated SmartConnect port connections were inspected as well.
- Fresh Tcl regeneration matched the implementation BD's connections,
  component parameters, external ports and address map, and passed the
  generated-datapath comparison again. The clock-crossing XDC now uses
  late processing so all board and vendor clocks exist before its bounds
  are applied; no numerical timing constraint was relaxed.
- Diagnostics and SFP-sideband regressions passed.

The all-counter implementation and bitstream generation completed successfully
in `build/ip_refactor/production_bd/project/`. Final routed results:

| Metric | Production catalog assembly |
| --- | ---: |
| Setup WNS / TNS | +0.018 ns / 0.000 ns |
| Hold WHS / THS | +0.011 ns / 0.000 ns |
| LUTs | 29,050 |
| Registers | 36,982 |
| Block RAM tiles | 51.5 |
| DSPs | 0 |
| Unclocked pins / unconstrained internal endpoints | 0 / 0 |

All retained RGMII instance/clock targets and constrained PS, PL and SFP
clock names resolve. The successful implementation run has zero critical
warnings and errors. DRC reports only the two existing AXI DMA BRAM
collision advisories. CDC remains unwaived: 2,632 CDC-1, 13 CDC-10 and
8 CDC-12 critical findings, matching the previous partition's category
counts. Seven inputs and eleven outputs still lack external delay
constraints. Positive slack is not complete CDC/external-I/O sign-off.
Reports are under `build/ip_refactor/production_bd/reports/`.

Bitstream: `build/ip_refactor/production_bd/project/kr260_switch.runs/impl_1/kr260_top.bit`.
SHA-256: `f718231385c739efa01e5e0cac625fc34eeedcfe7dbb90c34506937430484c0c`.

This assembly was downloaded over JTAG with matching all-counter R5 firmware.
See the board acceptance results above. Older sections retain their original
image-specific evidence.

## 2026-09-25 repository checkpoint

The `begin partition to ip repo centric flow` checkpoint includes the initial
digital IP partition and the previously uncommitted standalone-R5 USB storage,
persistent configuration and administrator-authentication work. The root
README, dependency notices and development inventory reflect the deployed
state and distinguish completed work from the remaining physical-IP migration.

Before check-in, the all-counter R5 build/ELF audit and complete firmware host
tests passed. The browser regression passed using the local Node 22/Playwright
installation, covering navigation, refresh, counter precision, sensor formatting,
port/IP settings, MAC allocation and storage availability. IP catalog source,
interface and clock/reset checks passed; the staged whitespace check is clean.
Generated catalogs, FPGA outputs, firmware binaries and local test logs are
excluded from the commit. Earlier RTL, routing and hardware evidence follows.

## 2026-09-25 partitioned design downloaded and connectivity checked

Loaded the partitioned all-counter bitstream from
`build/vivado_kr260_modular/kr260_switch.runs/impl_1/kr260_top.bit` through
the KR260 PS TAP on `10.0.1.107:3121`. Rebuilt and started the standalone R5
firmware with `STATS_DDR=1 STATS_DEBUG=1 CONFIG_RECOVERY=0`. ELF checks passed;
UART confirmed matching capabilities `0x53540107`, enabled D-cache and
successful SD configuration loading. STP remains disabled.

The first DHCP attempt failed; the scheduled retry succeeded at
**10.0.1.104**. GEM1 (right lower) and PL0 (left upper) report 1000 Mb/s;
the other physical links are down. Tests were bound to workstation `eth1`:

| Target/test | Result |
| --- | --- |
| KR260 normal ping | 100/100 replies |
| KR260 1472-byte payload, DF, A55A pattern | 100/100 replies |
| Endpoint 10.0.1.140 initial full-MTU run | First 50 requests lost; next 50 replied |
| Endpoint repeat, normal/full-MTU | 30/30 and 30/30 replies |
| Endpoint settled full-MTU, DF, A55A pattern | 200/200 replies |
| Web statistics page and configuration/ports/statistics APIs | HTTP success |
| SNMP | All counter groups readable; collector advancing |

The final SNMP snapshot, after 695 collector polls, reported zero bad
RX/TX packets, DDR error responses, late polls, saturation or mailbox/snapshot
timeouts. GEM1/PL0 counters advanced during endpoint traffic. Saved SD
configuration remains present and writable; no settings were changed.

Connectivity is working after settling. The initial DHCP failure and roughly
five seconds of initial endpoint loss are recorded, not explained or claimed
fixed by this test. This does not validate disconnected ports or sustained
line-rate traffic. The board is left running the new image and firmware.
Logs and snapshots are in `build/ip_refactor/jtag_validation/`.

## 2026-09-25 digital IP partition verified and routed

The first [IP repository partition](ip-partitioning.md) separates the fabric
and GEM counter ownership while preserving the board-facing interface.
All four DDR/debug counter combinations passed the original-versus-partitioned
simulation: 114 outputs checked over 29,922 clock samples per run, with
1,326–1,591 completed statistics snapshots. Shared legacy leaf RTL was checked
against the immutable reference commit so changes cannot be hidden by using
the same modified leaf in both designs.

The module regression passed buffer ownership, ingress/egress, GEM, GEM/egress
integration, PL adapters, SFP, CPU port, forwarding, counters, GEM multirate,
ingress pipeline and diagnostics tests. Vivado generated all five IP types;
the separate seven-instance validation BD passed validation/generation without
warnings. The generated BD elaborated in Icarus against the packaged source
files. An additional all-counter run through Vivado's generated IP wrappers
passed the same 114-output comparison and 1,326 snapshot reads. Packaging
source hashes, bus widths, clocks, resets and legal parameters were checked.

An isolated **all-counter** KR260 build completed synthesis, routing and
bitstream generation in `build/vivado_kr260_modular/`:

| Routed result | Value |
| --- | ---: |
| WNS / TNS | +0.018 ns / 0.000 ns |
| Worst hold slack / total hold slack | +0.010 ns / 0.000 ns |
| Unclocked register/latch pins | 0 |
| Unconstrained internal endpoints | 0 |
| CLB LUTs / registers | 30,831 / 37,894 |
| Block RAM tiles | 51.5 |
| DSPs | 0 |

The bitstream is
`build/vivado_kr260_modular/kr260_switch.runs/impl_1/kr260_top.bit`, SHA-256
`785b9b353feb7137828b1d0e17b923c568df421f521967917d5baef112634a3d`.
Both RGMII forwarded-clock constraints still resolve to their intended
instances. DRC reports two vendor AXI-DMA BRAM collision advisories and no
errors. This build meets the existing constraints; the positive margins
are small and do not constitute complete external-interface sign-off.

The routed CDC report still needs protocol-aware review: CDC-1=2,632,
CDC-10=13 and CDC-12=8 critical findings. The latter groups include the
statistics request decode and shared acknowledgment mux. No new crossing
logic was introduced by this structural split; these findings are **not
automatically waived** by simulation equivalence. Existing missing external
I/O-delay constraints and the earlier STP/CPU-tag concerns remain open.
This run is not a completed CDC sign-off or a six-port saturation test.

Evidence is in `build/ip_refactor/`; `ip_repo/review_board.tcl` reproduces
the routed reports. The production board assembly still uses the native
RTL module instances from the manifests. The physical-shell and production
BD migration remains listed in [partitioning](ip-partitioning.md).
The image was subsequently downloaded with matching firmware; the hardware
connectivity results are recorded above.

## 2026-09-24 R5 USB microSD configuration verified

The standalone R5 enumerated the onboard USB2244 reader and mounted the user's
FAT32 card (31,116,288 x 512-byte sectors). Defaults were selected with no saved
record. Unauthenticated configuration POST returned 401; authenticated save and
readback returned 200. The initial save failed because the reader rejects SCSI
SYNCHRONIZE CACHE with sense 05/20/00 and reports only mode page 05. A compatibility
path restricted to this VID/PID, that sense code, and valid mode data without an
enabled write cache now accepts completed write-through transfers. Host tests
cover its error and malformed-response rejection paths.

Saved defaults, then temporarily disabled unused PL1, performed full PS/FSBL/USB
reset and reload, and verified the saved mask 23. Restored mask 31, saved again,
and repeated full reset; UART reported loaded settings and the API confirmed
`saved=true`, `writable=true`, all ports enabled. DHCP assigned `10.0.1.104` to
`00:0a:35:0f:37:45`. Credentials remain `admin` / `admin`.

The hardware host is now `10.0.1.107` (JTAG 3121, UART 2323). With a Kintex FPGA
also attached, XSDB requires selecting `PS TAP`, not `PL`, before programming.
The boot script was corrected. The default FPGA image exposes caps `0x53540101`;
this deployment explicitly used the validated pipelined-ingress all-counter image
with matching firmware (`0x53540107`). STP remains disabled; this image predates
the STP hardware hooks. GEM1 is the only active physical link, at 1000 Mb/s.

One late ping run lost 9/10 replies; subsequent small Ethernet-bound pings and
HTTP also failed temporarily. JTAG found the idle task running, links admitted,
and DMA without error. Connectivity recovered without resetting firmware. Later
normal and Ethernet-bound full-MTU runs passed, followed by 30/30 replies during
ten successful repeated configuration/card-status reads. SNMP showed no collector
timeouts, packet errors or AXI errors in sampled counters. The transient's cause
is unconfirmed and remains a follow-up; this is not a sustained-load qualification.

All firmware host tests and ELF checks pass. Physical power-cycle retention and
card removal/replacement remain pending. Logs are local ignored artifacts in
`build/r5/sd_validation/`; see [USB storage](usb-storage.md).

## 2026-09-23 autonegotiation regression expectation corrected

Resolved the previously recorded `sim-autoneg` test-C failure (16 received
bytes versus 17 expected). Its fixed expectation assumed six post-/S/
preamble bytes, but an odd-position GMII start produces five. The SFD and
all ten payload bytes were intact, with no RX errors. This was a testbench
expectation defect; no production RTL change was required.

`tb_autoneg_1000base_x.sv` now explicitly drives both even and odd start
positions in both directions, checking the exact corresponding preamble,
SFD, payload and absence of RX errors. Stimulus and checks use falling
edges to avoid races with rising-edge DUT and receive-monitor sampling.
Failures and the global timeout now use `$fatal(1)` so Make sees failure.

Validation: `sim-autoneg`, `sim-sfp-rx-preamble` and `sim-sfp-tx-alignment`
all pass. Temporary in-memory mutations of the preamble expectation,
received payload and timeout each failed with exit status 1. Negotiation,
link loss and renegotiation still pass. No hardware rebuild or download
was needed for this simulation-only correction.

## 2026-09-23 SNMP observation (01:26:29–01:26:59 PDT)

Seven snapshots at five-second intervals from `10.0.1.214` showed GEM0 and
GEM1 up at 1000 Mb/s; PL0, PL1 and SFP were down. This observation predates
the STP work recorded below and does not validate that implementation.
Raw samples are retained locally in
`build/r5/snmp_observation_20260923/samples.jsonl` (ignored build artifact).

- All accumulated bad-packet/bad-byte counters and DDR AXI error responses
  were zero. Collection health showed zero mailbox-release or snapshot-response
  timeouts, late polls and saturated reads over 265,102 polls (about 18.4 hours).
- Physical ingress wrote 123,582 bytes in 852 bursts during the 30-second
  window. Write-data stalls rose by 1,704: exactly two cycles per burst.
  Address stalls were zero. This remains an optimization investigation;
  the observation alone does not establish its cause.
- GEM1 ingress/egress backpressure increased by 39/7,076 fabric cycles;
  CPU enqueue waiting increased by 2,462 cycles across 410 packets
  (about six cycles per packet). GEM0 ingress stalls remained zero.
- DDR latency maxima did not increase: physical ingress 1.35 us, physical
  egress 2.30 us, CPU write 3.20 us and CPU read 1.49 us at 100 MHz.
- Sensor validity was `0x7`, sensor errors were zero, PS temperature was
  31.8–33.4 C and PL temperature 30.9–32.4 C. SOM readings were approximately
  5.060 V, 0.829 A and 4.2 W.

These are light-traffic observations, not a throughput or overload test.

## 2026-09-23 check-in review: remaining STP limitations

Check-in validation passed: all-counter R5 build (`STATS_DDR=1
STATS_DEBUG=1`), ELF memory/vector audit, all firmware host tests, and
`sim-bufmgr`, `sim-ingress`, `sim-mac-fwd`, `sim-switch-top`, `sim-rx-diag`
plus the standalone `tb_ctrl_value_xdomain` behavioral test. The browser
regression also passed navigation, polling, precision and speed controls. These checks
did not rebuild or download hardware. The previously recorded full-suite
`sim-autoneg` failure below was subsequently resolved by the testbench
correction recorded above; the affected tests in this check-in passed.

STP defaults disabled. The TX mutex protects DMA descriptors and buffers,
but `pstate_cpu_tx_raw()` arms `CPU_TX_OVERRIDE` **before** acquiring that
mutex in `fabric_dma_send()`. Another sender can consume the override;
a failed send can also leave it armed. Override selection and descriptor
submission still need one serialized transaction with failure cleanup.
The IP receive callback and STP task also both mutate the STP engine and
apply actions; task ownership/serialization needs review before enabling it.

The override CDC launches data and toggle together through independent
synchronizers. Equal pipeline depths do not guarantee coherent sampling
on silicon; behavioral simulation does not model metastability. A held-data
handshake or asynchronous FIFO and physical CDC review remain pending.
CPU RX tag FIFO overflow and reset/error alignment with DMA completions
also need validation. TCN propagation/fast aging, web enable controls and
configuration persistence remain unimplemented. Passing the triangle test
is not a proof of general STP correctness or protocol conformance.

## 2026-09-23 real bug: CPU TX race between the IP stack and STP

Found on real hardware, not in simulation: shortly after connecting a real
adjacent switch with STP enabled, the board became unreachable (ping/HTTP
both failed). JTAG readback of `LINK_STATUS` (`0x80100014`) showed `0`
(every port, including the CPU, de-admitted) and the AXI DMA MM2S status
register (`0x80000004`) had bit 8 (SGIntErr) set. Root cause:
`fabric_dma_send()`'s shared `tx[]`/`tx_data[]`/`tx_index` state was written
from two independent FreeRTOS tasks with no serialization — the IP task
(ordinary IP-stack output via `network.c`'s `output()`) and the new
`stp_task` (BPDU transmission via `pstate_cpu_tx_raw()`) — a contract
`pstate.h`'s own header already documented ("Callers must not have another
CPU transmit in flight... serialize... e.g. by only calling it from the
same task/context that owns fabric_dma_send()") but `stp_task.c` violated
by calling it from its own separate task. The race could corrupt an
in-flight TX descriptor, producing the observed SG Internal Error, which
`network.c`'s existing DMA-fault fail-safe correctly (if drastically)
responds to by de-admitting every port -- a real, if latent, pre-existing
concurrency bug that a second CPU-TX caller (STP) was needed to expose.

Fixed in `fabric_dma.c`: `fabric_dma_send()` now takes a FreeRTOS mutex
(`SemaphoreHandle_t tx_lock`, created in `fabric_dma_init()`) around its
whole body, not a critical section (the function blocks on DMA completion
via `vTaskDelay`, which a critical section must never do). `tests/fakes/`
gained a trivial `semphr.h`/`portMAX_DELAY` fake (single-threaded, always
succeeds) so `test_dma` keeps building; no test behavior change, since the
existing tests are sequential and the fakes are no-ops. Rebuilt and
JTAG-redeployed; the board recovered and stayed reachable through a full
STP convergence cycle with a real neighbor.

## 2026-09-23 STP protocol implementation

Real classic 802.1D-1998 STP now runs in firmware (`software/r5/src/stp.c`,
`stp_task.c`) on top of the same-day hardware/software hooks below, plus one
new hardware feature: a CPU RX ingress-port tag threaded through
`buf_mgr_core`/`queue_mgr`'s per-buffer metadata (mirroring the existing
`length` field) and exposed via `rx_diag_regs`'s new `CPU_RX_TAG` register
(`0x50`).

`tests/test_stp.c` (host, `make -C software/r5 test-stp`, part of `test`):
four tests, all passing —

- `test_bpdu_wire_format`: a lone bridge's transmitted Config BPDU has the
  correct dest MAC/LLC/protocol-id/version/type bytes and root==self.
- `test_aging_reclaims_designated`: a port whose neighbor stops advertising
  (no clean link-down) ages out after Max Age (20 s) and is reclaimed as
  locally designated.
- `test_malformed_frames_ignored`: garbage, truncated, and out-of-range-port
  BPDU calls are ignored without miscounting or crashing.
- `test_triangle`: a bounded topology regression — three bridge instances wired A-B, B-C, C-A
  (a real physical loop) converge to exactly one root (lowest MAC, as
  intended) and exactly one blocked port network-wide; all role/state
  assignments match the hand-computed expected result for that topology,
  including the tie-break on the equal-cost B-C segment. Confirmed the test
  actually discriminates: a mutated cost-comparison direction breaks
  `test_triangle`'s root-election assertion (`sed`-based inline mutation,
  reverted after).

RTL: the new `enqueue_meta_i`/`dequeue_meta_o` plumbing (`queue_mgr.sv`,
`buf_mgr_core.sv`, `ingress_top.sv`) and the new `async_fifo`/`CPU_RX_TAG`
crossing (`switch_top.sv`, `rx_diag_regs.sv`) are covered by extensions to
`tb_switch_top.sv` (a GEM0-sourced frame delivered to the CPU is tagged
with ingress port 0, and popping drains it) and `tb_rx_diag.sv` (register
format, pop-pulses-on-every-read, valid/invalid readback). Both mutation-
tested: tying `enqueue_meta[gi]` to a wrong constant in `ingress_top.sv`
correctly failed `tb_switch_top`'s new assertion, confirmed then reverted.
Full `sim/Makefile` regression re-run afterward (295 PASS markers,
the same one pre-existing unrelated `sim-autoneg` failure as the
2026-09-23 STP-hooks entry below, still confirmed unrelated).

Firmware: `make -C software/r5 -j8 all test` passes in full, including the
real ARM cross-build/link, `verify_elf.py`, and every existing host test
(`test_dma`'s fake `board.h` needed `DIAG_BASE`/`CPU_RX_TAG` added since
`fabric_dma.c` now reads that register on every RX descriptor). The web
statistics page gained an `"stp"` JSON object and a rendered table
(bridge/root identity, per-port role/state/BPDU counters) — the way to
visually confirm STP is running and converged on real hardware.

`rtl/board/kr260_pl_top.sv`'s updated wiring (the new `cpu_rx_tag_*`
connections between `switch_top` and `rx_diag_regs`) was validated with
the real Vivado 2026.1 `build_kr260.tcl`/`impl_kr260.tcl` flow: bitstream
generated successfully (0 errors throughout synthesis/implementation/
bitgen), DRC 0 errors (the same two pre-existing DMA-IP BRAM advisories as
every prior build, unrelated to this change), and the automated pass/fail
check reported "Normal image verified: no debug cores; setup and hold
timing met." WNS +0.018 ns / WHS +0.010 ns, unchanged from the prior
baseline -- the new `async_fifo` crossing for `CPU_RX_TAG` falls inside
the already-documented `clk_pl_0` clock pair, not a new one.

## 2026-09-23 STP hardware/software hooks

New/extended testbenches for the control-protocol hooks described in
[architecture](architecture.md#control-protocol-hooks-stplacplldp-no-protocol-logic):

| Target | Testbench | New coverage | Result |
| --- | --- | --- | --- |
| `sim-ctrl-value-xdomain` (direct `iverilog`/`vvp`, not yet a named Makefile target) | [`tb_ctrl_value_xdomain.sv`](../tb/tb_ctrl_value_xdomain.sv) | 200 random-value/random-phase single crossings; single-cycle pulse width; 100 racing-write trials at 0-3 source-clock gaps asserting no torn value | PASS |
| `sim-mac-fwd` | [`tb_mac_forwarding_top.sv`](../tb/tb_mac_forwarding_top.sv) | Reserved-block trap to CPU-only with `ctrl_frame_o` (BPDU and LLDP addresses, plus an untrapped boundary address that still floods); trapped source MACs still learned; `fwd_en_i`/`learn_en_i` per-port gating of ordinary traffic, forwarding gate bypassed for trapped frames; learning remains gated | PASS |
| `sim-switch-top` | [`tb_switch_top.sv`](../tb/tb_switch_top.sv) | `fwd_en_i[0]=0` drops GEM0's ordinary traffic but still delivers its BPDUs to the CPU byte-for-byte; CPU TX override sends a frame to exactly one software-chosen port then disarms, and a later un-overridden send resolves normally | PASS |
| `sim-rx-diag` | [`tb_rx_diag.sv`](../tb/tb_rx_diag.sv) | FWD_SET/CLR and LEARN_SET/CLR register writes, verified flush-toggle deltas; PORT_CTRL_STATUS readback; CPU_TX_OVERRIDE bit31 gating (both armed and not-armed, checked cycle-by-cycle) | PASS |

Each new RTL behavior above was confirmed by a targeted mutation (breaking
the control-block trap, the `fwd_en_i`/`learn_en_i` gates, the CPU TX
override mux, and the register flush-OR/bit31 gate) and reverted after
confirming the corresponding test failed with a specific message.

Full regression (all `sim-*` targets in `sim/Makefile`, run together) shows
no regressions from these changes: 294 PASS markers, one FAIL —
`sim-autoneg`'s `tb_autoneg_1000base_x.sv` testC ("A received 16 bytes,
expected 17") — confirmed pre-existing (reproduces identically with these
changes stashed out, on unmodified `autoneg_1000base_x.sv`/
`sfp_1000base_x_pcs.sv`/`tb_autoneg_1000base_x.sv`), deterministic across
repeated runs, and out of scope for this change.

Firmware: `make -C software/r5 -j8 all test` passes, including the new
`test-pstate` target (register-plumbing mutation-style checks: each
`pstate_*` call writes/reads the exact register offset packed the way
`rx_diag_regs.sv` expects, out-of-range port bits are masked, DMA failure
propagates, and the default weak `fabric_ctrl_frame_rx` hook is a true
no-op). The real ARM cross-build/link succeeds and `verify_elf.py` passes
both its DMA-isolation and entry/vector/symbol/reserved-memory checks with
`pstate.c` linked in.

`rtl/board/kr260_pl_top.sv`'s new wiring (the one file using real UNISIM
primitives that Icarus cannot elaborate) was validated with the real
`build_kr260.tcl -tclargs synth` then `impl_kr260.tcl` Vivado 2026.1 flow.
Result: bitstream generated successfully (`Bitgen Completed Successfully`,
217 Infos/22 Warnings/0 Critical Warnings/0 Errors), DRC 0 errors (the only
two warnings are a pre-existing DMA-IP BRAM NO_CHANGE collision advisory,
unrelated to this change), and `impl_kr260.tcl`'s own automated pass/fail
check (no debug cores, worst setup and hold slack both non-negative)
reported "Normal image verified: no debug cores; setup and hold timing
met." WNS +0.018 ns / WHS +0.010 ns, unchanged from the last recorded
baseline in [inventory](inventory.md). `report_cdc`/`report_cdc -summary`
show the same 13 clock-pair groups already catalogued in
[cdc-review](cdc-review.md); the new `learn_en_i`/`fwd_en_i` synchronizer
and the `ctrl_value_xdomain` CPU-TX-override crossing both land inside the
already-documented `clk_pl_0` → `clk_out3_pl_eth_clk_gen_ip` pair (same
pairing `port_link_ctrl`'s existing crossings use), not a new clock-pair
group. `report_methodology` shows no new findings attributable to
`rx_diag_regs.sv`, `switch_top.sv`, `ctrl_value_xdomain.sv` or
`kr260_pl_top.sv`.

## 2026-09-22 current display precision update

The web page now renders SOM current with exactly three decimal places, such
as `0.800 A`, matching voltage precision. Temperatures retain one decimal place.
Only display formatting changed; raw sensor readings and SNMP/API units are
unchanged. The R5 application was rebuilt, passed the ELF memory/vector audit,
and loaded with the existing pipelined-ingress bitstream. Live Chromium
verified `SOM current 0.825 A`. No boot flash was written.

Firmware SHA-256 deployed for this dated validation:
`8b3447e383e644796c9e0a9d3cad06dfebb5dcc72f2a17e32a9eeb99106a122e`.
Build/boot logs, firmware copy and browser result are retained under
`build/r5/current_format_validation/`. Speed-test wiring remains GEM0 to the
endpoint, GEM1 to the managed switch, and SFP disconnected. Defaults remain
all ports enabled, GEM0 advertising 1000FD, and GEM1 advertising 10/100/1000FD.

## 2026-09-22 PS link speeds and web sensor precision

Implemented 10/100/1000 full-duplex advertisement/configuration for GEM1
(right lower, RGMII), plus speed reporting in HTTP/SNMP and web capability
controls. GEM0 remains 1000-only: AMD UG1087 explicitly excludes 10/100 from
the PS SGMII path. Experimental GEM0 100 Mb/s copper negotiation did not
produce working forwarding, but that test also used the gigabit-only endpoint
and cannot isolate the cause. The GEM0 restriction follows AMD documentation;
the final firmware rejects unsupported lower-speed GEM0 settings. No production RTL or FPGA bitstream change was needed.

The first GEM1 100 Mb/s test used endpoint `10.0.1.140`; its PHY negotiated
100, but pings failed. The user confirmed that endpoint's MAC/firmware is
currently gigabit-only. Restoring GEM1 to 1000-only recovered 5/5 pings.
For valid lower-speed tests, the user moved the endpoint back to GEM0 and
connected the managed-switch uplink to GEM1, leaving SFP disconnected.

At each of GEM1's 100FD-only, 10FD-only, 1000FD-only and all-speed settings:

- The PHY resolved to the expected 100, 10, 1000, and 1000 Mb/s respectively.
- Both R5 `10.0.1.214` and forwarded endpoint `10.0.1.140` passed 20/20
  full-MTU pings (1472-byte ICMP payload) per setting.
- HTTP remained available after renegotiation; SNMP reported the matching
  physical speed and advertisement mask.
- Final samples at each setting had zero bad packets/bytes, statistics
  timeouts, late polls and saturation. These are light-traffic checks, not
  sustained overload or lossless speed-transition qualification.

Host firmware tests pass, including real link-service sequencing against a
register/MDIO model, half-duplex rejection, unsupported advertisement rejection,
SNMP object walking and HTTP parsing with all four counter build options.
The GEM FIFO bridge bench passes at 125, 25 and 2.5 MHz. Browser fixture tests
verify speed/capability controls and exact voltage/temperature formatting.
The final web page additionally refreshes link/speed cells every second
without replacing unsaved checkbox edits. Voltages use three decimal places;
temperatures use one. Raw API/SNMP sensor values are unchanged.

Evidence and exact firmware images are under `build/r5/multirate_validation/`.
`tested_rates_r5.elf` is the rate-tested image; `kr260_r5.elf` includes the
subsequent configuration-page status refresh. Both use the existing
pipelined-ingress bitstream. See [PS speed details](ps-ethernet-speeds.md).

Firmware SHA-256 before the current-format update below:
`7dfcc8fbd16719aae35517625137c38454da3df0363520d6ad08784a5a5553ff`.
After the final reload, live Chromium verified voltage/temperature formatting
and disabled GEM0 lower-speed controls; SNMP reported GEM0/GEM1 at 1000 Mb/s
with advertisement masks 4/7. Endpoint full-MTU pings passed 10/10.
Current wiring is GEM0 to the endpoint, GEM1 to the managed switch, SFP
disconnected. All five physical ports remain administratively enabled.


## 2026-09-22 R5 web management

Added HTTP configuration/statistics pages and loaded the all-counter R5 build
with the existing pipelined-ingress FPGA bitstream. Host parser/JSON tests pass
under ASan/UBSan with all four statistics build combinations; existing policy,
DMA, statistics and SNMP regressions pass. Firmware memory/vector verification
passes. Browser tests verify separate pages, one-second refreshing, exact
64-bit totals, configuration POSTs, and desktop/mobile rendering. Live Chromium
loads both pages and refreshes statistics without JavaScript errors.

Live test at `10.0.1.214`: administrative mask 31/physical mask 17/forwarding
mask 17 initially; disabling GEM0 changes administrative mask to 30 and
forwarding mask to 16 while physical mask remains 17. Endpoint
`10.0.1.140` stops answering pings; R5 management stays reachable through SFP.
Restoring mask 31 restores forwarding and passes 10/10 endpoint pings.
Ten subsequent statistics samples advance normally. SNMP remains accessible;
collector late polls, saturation and sensor errors remain zero in the final
sample. One snapshot-response timeout was recorded at bank 2, slot 0
(GEM1 RX good packets); no mailbox-release timeout was recorded.
Disconnected-port traffic isolation and disabling the SFP
management uplink were not tested live. All ports were left enabled.

After the firmware/FPGA reload, SFP initially had PCS sync but no completed
negotiation (`PCS_STATUS=1`); the module copper PHY reported a resolved link.
A 500 ms TX_DISABLE pulse through the existing sideband control restored
`PCS_STATUS=7`, and the existing one-minute DHCP retry acquired `10.0.1.214`.
This startup negotiation recovery issue remains separate from HTTP behavior;
no automatic SFP recovery change was included.

Evidence, screenshots, boot logs, exact firmware copy and SHA-256 manifest:
`build/r5/web_validation/`. The volatile JTAG load does not change boot flash.
See [web-interface.md](web-interface.md) for behavior and API details.

Deployed firmware SHA-256:
`15535c10b708c8ededddc62ad675be53079c3f362db51be3ec0fd865777b5053`.
The user confirmed unchanged SFP managed-switch uplink and GEM0 endpoint
connections after validation. The board runs this web-enabled firmware with
the pipelined-ingress bitstream described below.

## 2026-09-22 pipelined DMA bitstream deployment

Loaded `build/r5/ingress_pipeline_validation/kr260_ingress_pipeline.bit`
through JTAG with the latest per-index timeout diagnostic firmware. Bitstream
SHA-256: `2455aed75db5dc661de592958cc139fe68a1ef9ea80103f942ee0456814bf5ed`;
firmware SHA-256: `a83338763d34dc4b3fdc5eb19b7a52fb7b9f4e01bcba7055e8800ebe8e66c77b`.
Flash was unchanged; the PS reset also reset all software statistics totals.

- DHCP acquired `10.0.1.214`; GEM0 and SFP came up without manual recovery.
- Simultaneous full-MTU ping tests passed 100/100 to the R5 and 100/100 to
  endpoint `10.0.1.140`. SNMP polling continued during traffic.
- Final sample: zero bad packets/bytes on all ports, zero AXI errors, zero
  statistics timeouts, late polls or saturated reads. Sensor validity mask 7,
  errors 0. This short test does not establish that the GEM1 timeout is fixed.
- Across before/after snapshots, physical ingress writes completed 1,445
  bursts with 2,890 data-stall cycles: **two cycles per burst**. These are
  downstream WREADY stalls, which the internal read/write pipeline does not
  promise to eliminate. The faster WVALID cadence can expose backpressure
  previously hidden by internal idle cycles; the exact stall timing was not
  captured here.
- The maximum observed physical ingress write latency was 135 fabric cycles
  (1.35 us), versus 226 cycles (2.26 us) in the earlier old-image sample.
  Traffic mixes differ, so this is not a controlled performance comparison.
  The simulation comparison below is the controlled measurement of DMA cadence.

Evidence, UART/boot logs, firmware copy, pings and SNMP snapshots are under
`build/r5/ingress_pipeline_validation/board/`; the parent manifest records
programming status and validation. The subsequent web deployment retains this
FPGA image and updates the R5 firmware.

## 2026-09-22 timeout bank/slot diagnostics

Firmware now counts mailbox-release and snapshot-response timeouts separately
for each implemented hardware bank/slot. It also records the last release
active index, release target index and snapshot-response index. Sentinel
4294967295 means no event since R5 restart. The active INDEX register is read
only on a release timeout; hardware clear-on-read statistics ownership is
unchanged. SNMP has three additional health scalars and a bank/slot-indexed
timeout table; the reader labels nonzero rows and decodes the last indices.

- `make -C software/r5 test` passes. Statistics tests verify attribution to a
  nonzero bank/slot, active-versus-target release indices, class/table sums,
  initial sentinels and pending-request retry. Twelve SNMP tests pass for each
  of four counter builds, including two-index table exceptions and walking.
- Net-SNMP and the reader script pass against a host fixture with deliberately
  different active/target indices and nonzero counts. The MIB resolves symbolic
  names correctly. The SNMP object capacity was raised to 384 to hold the
  expanded tree; request/response bounds and UDP queue limits are unchanged.
- R5 built with both optional statistics categories and passed the ELF audit.
  Deployed SHA-256:
  `a83338763d34dc4b3fdc5eb19b7a52fb7b9f4e01bcba7055e8800ebe8e66c77b`.
- Loaded using the unchanged, previously deployed all-counter bitstream.
  DHCP acquired `10.0.1.214`; GEM0 and SFP links came up. The newly built
  ingress-pipeline bitstream was deliberately not loaded during this diagnostic
  update, preserving the hardware under investigation. Flash was unchanged.
- Live Net-SNMP walk returned 348 project instances (plus an end-of-view line).
  Seven reader samples verified the per-index sums against class totals, with
  no timeouts, late polls or saturation. All last indices were the no-event
  sentinel following reset. Full-MTU pings passed 50/50 to the R5 and 50/50
  to endpoint `10.0.1.140` during sampling.

The earlier timeout cannot be located retrospectively; these new counters
will identify future occurrences. Firmware and logs are retained under
`build/r5/timeout_index_validation/`. This is diagnostic instrumentation,
not a timeout root-cause fix.

## 2026-09-22 physical ingress DMA pipelining

The physical-port ingress write engine now overlaps synchronous packet-RAM
reads with AXI W transfers. A two-word buffer accounts for queued words and
the one-cycle read in flight before issuing another read. AXI backpressure
halts read-ahead without overwriting data; accepted beat count determines
WSTRB and WLAST. Address sequencing, per-frame arbitration and waiting for B
before completion are preserved. CPU write DMA is unchanged.

Simulation was completed before starting the isolated all-counter hardware
build. Reproduce the primary checks with:

```sh
make -C sim sim-ingress-pipeline sim-ingress sim-switch-top sim-integ sim-statistics
make -C sim lint-ingress
make -C sim sim-ingress-pipeline-verilator
```

- The new bench passes 2,372 cases per run: every length from 1 through 2,048
  bytes, distributed across five ports; 300 randomized-backpressure frames;
  stalls on the final beat; long initial data stalls; delayed address and
  response handshakes; resets with stalled AW, buffered reads and pending B.
  Checks include exact data, strobes, WLAST, no extra RAM reads, stable AXI
  values under backpressure, correct completion timing and consecutive beats.
- Three Icarus runs with different random seeds pass. The same 2,372-case
  bench also passes with Verilator, as does lint of the complete ingress
  subsystem. Existing ingress tests include actual
  packet RAM and concurrent ports; switch forwarding/link-flush, GEM transmit
  integration and statistics regressions also pass.
- Running the same bench against the pre-change DMA confirms the throughput
  comparison below. The baseline enables its expected two-cycle beat cadence.

| 1,500-byte frame, 94 beats, always-ready AXI | Before | Pipelined |
| --- | ---: | ---: |
| AW handshake to final W handshake | 188 cycles | 96 cycles |
| First through final W handshake, inclusive | 187 cycles | 94 cycles |
| Steady data cadence | 2 cycles/beat | 1 cycle/beat |

At 100 MHz, the address-to-last-data interval falls from 1.88 us to 0.96 us.
These measurements exclude B-response latency, per-frame arbitration and
queue management. They do not establish sustained system throughput or
eliminate downstream AXI backpressure; the previously observed one stall per
burst can remain. The extra buffering also adds startup latency to very short
bursts compared with the former direct RAM-to-W path.

Hardware build completed with `STATS_DDR=1 STATS_DEBUG=1` in the isolated
`build/r5/ingress_pipeline_vivado/` project. Final setup WNS is +0.018 ns,
hold WHS +0.010 ns, TNS/THS zero under the existing constraints. Utilization:
29,873 LUTs, 37,738 registers, 51.5 BRAM tiles. No debug cores were inserted.
The bitstream and XSA are `build/r5/ingress_pipeline_validation/kr260_ingress_pipeline.bit`
and `.xsa`; reports, source/artifact hashes and simulation evidence are in
that directory. The optimized bitstream was subsequently downloaded and passed the board
checks recorded above.

## 2026-09-22 separate timeout counters

Added software Counter32 totals for mailbox-release deadline expiry and
hardware snapshot-response timeout, while preserving the existing combined
timeout total and retry behavior. SNMP health scalars 10 and 11 and the
reader script expose the split; no hardware change was required.

- Host statistics tests distinguish a stuck BUSY-release path from a DATA
  timeout and verify that the combined total equals the two classes' sum.
  Eleven SNMP tests pass for each of the four optional-counter build combinations,
  including the new scalar OIDs, types and values. Existing policy/DMA tests pass.
- R5 built with `STATS_DDR=1 STATS_DEBUG=1`; ELF memory/vector audit passes.
  Deployed ELF SHA-256:
  `ab5a9381bd60b6357456243a7bd7ffae08b9298f32f692ec78b34d4c041c8b03`.
- Loaded through the existing JTAG boot flow with the unchanged all-counter
  bitstream; flash was not modified. GEM0 and SFP links came up without the
  manual TX_DISABLE pulse needed on the earlier boot. Initial DHCP failed;
  the automatic minute retry acquired `10.0.1.214`.
- Live SNMP reads verified both new fields. Seven samples during simultaneous
  full-MTU pings showed total/release/response timeout counts all zero;
  availability was true, with zero late polls and saturated reads.
- Full-MTU pings passed 50/50 to the R5 and 50/50 to endpoint `10.0.1.140`.

The reload reset all accumulated totals, including the previous 21 timeouts.
No natural timeout occurred during the initial short validation. Subsequently,
while the same deployed image was running and the ingress pipeline build was
underway, SNMP reported total=1, mailbox_release_timeouts=0 and
snapshot_response_timeouts=1. This confirms at least one hardware DATA-response
timeout, rather than a software BUSY-release deadline. It does not establish
the affected source domain or root cause. Bank/index logging remains
unimplemented. Local firmware, UART/boot logs, samples and test results are
preserved under `build/r5/timeout_validation/`.

## 2026-09-21 live SNMP counter observation

The reader script sampled `10.0.1.214` seven times at five-second intervals,
from 21:40:53 through 21:41:23 America/Los_Angeles, under existing background
traffic plus the SNMP queries. No additional load was generated for this check.

- Collection remained available with all counter groups enabled. Polls advanced
  from 2,870 to 2,990: exactly four scans per second. Late polls and saturated
  reads remained zero.
- **Mailbox read timeouts totaled 2**, increased from 1 in the earlier SNMP
  validation. The total stayed at 2 during this observation. Collection
  continued; current diagnostics cannot identify the bank/index or distinguish
  a mailbox-release wait timeout from a DATA-response timeout. Add those
  diagnostics before attributing this to a specific clock domain or mechanism.
- All ports reported zero bad packets and zero bad bytes, in both directions.
  GEM0, SFP and CPU remained up. GEM1, PL0 and PL1 remained down with zero
  traffic. Packet deltas (RX/TX) were GEM0 80/279, SFP 375/178, CPU 98/296.
  Flooding and the CPU-facing filter mean these are not expected to match
  one-to-one across ports.
- All four DDR error-response counters and the combined AXI-error counter
  remained zero. Measured completed-burst latency is below; maxima are since
  R5 restart, not just this interval.

| DDR path | Completed bursts in interval | Mean latency in interval | Maximum since restart |
| --- | ---: | ---: | ---: |
| Physical ingress write | 455 | 0.529 us | 2.270 us |
| Physical egress read | 457 | 0.557 us | 2.280 us |
| CPU write | 98 | 0.887 us | 3.200 us |
| CPU read | 296 | 0.488 us | 1.740 us |

Physical ingress writes added 455 data-stall cycles, one per completed burst;
other DDR address/data stall counts did not increase. CPU enqueue waiting
added 590 fabric cycles (5.9 us total). These small waits are backpressure,
not evidence of packet loss. Historical GEM0 egress stalls (18,780 cycles),
SFP ingress stalls (46) and link-flush busy cycles (2,561) did not increase.
CPU allocation waiting remained zero.

All sensor samples had validity mask 7 and error count 0. PS temperature
ranged 30.505–32.712 C; PL 29.790–31.189 C. SOM voltage was 5.060 V,
current 0.82625–0.82750 A, and power 4.18–4.19 W. Rail readings were present;
this check does not establish voltage tolerance or external calibration.

The main observed issue is the recurring statistics mailbox timeout. No
ongoing packet-error problem was observed, but this short, lightly loaded
sample does not validate line-rate behavior or long-term reliability.
Raw samples are retained locally in
`build/r5/snmp_validation/counter_observation.jsonl` (generated evidence,
not committed). Reproduce with:

```sh
python3 scripts/read_snmp_counters.py --interval 5 --count 7 --json
```

## 2026-09-21 SNMP agent validation

R5 firmware with read-only SNMPv2c was built with `STATS_DDR=1 STATS_DEBUG=1`
and loaded through JTAG using the existing `kr260_all_counters.bit`.
No FPGA source or bitstream change was needed for SNMP, and flash was unchanged.
The deployed ELF SHA-256 is
`251140e87f79e2fb59e4c3bf8f79dc28f39a037731694b86f32837597c6157b5`.
The previous statistics-only firmware remains preserved separately.

- `make -C software/r5 test` passes: existing policy, DMA and statistics
  tests plus ten SNMP tests for each of four counter build combinations.
  Tests include full unsigned 64-bit values, negative sensor values,
  lexicographic walks, GETBULK layout/truncation, malformed BER, invalid
  community/version, SET rejection, response bounds and request ID limits.
- An additional 100,000 random datagrams passed under address/undefined
  behavior sanitizers; 10,000 structured-message mutations also passed with
  undefined-behavior instrumentation. These are bounded checks, not a claim
  of exhaustive protocol/security validation.
- Net-SNMP 5.9.4 parsed the supplied MIB and interoperated with both the host
  fixture and the board. Numeric and symbolic GETs, GETNEXT walks and
  GETBULK walks succeeded. SET returned `notWritable`.
- The all-counter tree exposes 151 project instances, plus four standard
  system scalars. Thirty complete GETBULK walks passed in 6.42 seconds.
- Live port totals increased on GEM0, SFP and CPU; disconnected ports stayed
  at zero during the measured interval. Inspected port, DDR and debug values
  were nondecreasing. This verifies readout and activity, not exact accounting
  under line-rate traffic.
- Full-MTU pings: R5 `10.0.1.214` 100/100, endpoint `10.0.1.140` 100/100;
  another R5 run concurrent with repeated walks passed 200/200.
- Sensors reported validity mask 7, errors 0. One sample: PS 33.971 C,
  PL 31.888 C; PS LP/FP/AUX 0.839859/0.845718/1.802124 V;
  PL INT/AUX/BRAM 0.716629/1.791046/0.847229 V;
  SOM 5.060 V, 0.830 A, 4.200 W. These are device readings, not externally
  calibrated measurements, and SOM power excludes carrier-board loads.

Two follow-ups were exposed during deployment:

1. After JTAG reconfiguration the SFP had PCS sync but no negotiated link
   (`PCS_STATUS=1`), while GEM0 remained up. The operator confirmed unchanged
   cabling. A one-second pulse of SFP_CONTROL.TX_DISABLE restored PCS status 7
   and links 0x31; the existing DHCP retry then acquired `10.0.1.214`.
   No automatic recovery change was added. Determine why negotiation can
   stall across reconfiguration before claiming unattended restart reliability.
2. `krStatsReadTimeouts` rose from 0 to 1 during the initial traffic test.
   Collection continued, and the count remained 1 through repeated walks.
   Late-poll and saturation counts remained zero. The existing collector
   retries pending reads, but this observation does not identify the timed-out
   bank or establish the root cause. Add diagnosis if it recurs.

Local evidence and the deployed firmware copy are under
`build/r5/snmp_validation/`: UART/boot logs, before/after walks, GETNEXT walk,
symbolic queries, SET rejection, repeated walks, ping logs and manifest.
See [SNMP usage](snmp.md) and [MIB](mibs/KR260-SWITCH-MIB.txt).

## 2026-09-21 statistics and sensor extension

This extension has completed synthesis, place-and-route and bitstream generation
with all counters enabled, and was downloaded through JTAG on 2026-09-21.
DHCP and initial full-MTU ping checks passed. Subsequent SNMP validation
above verifies numerical sensor values and increasing live totals; prolonged
load and quantitative counter-accuracy testing remain pending.

- `make -C sim sim-statistics`: three new benches pass. Coverage includes
  asynchronous read/clear, simultaneous increments, overflow saturation,
  AXI response backpressure, stopped-clock timeout and late-snapshot retry;
  DDR byte strobes, latency sum/max, address/data stalls, error responses and
  a burst spanning a polling interval; GEM RX error/flush, GEM TX completion
  status/padding, and CPU AXI-stream backpressure/length classification.
- `sim-pl-linerate`: existing three line-rate cases pass, now also verifying
  exact RX/TX packet and byte counts, read/clear, and an injected bad-RX frame.
  This target now propagates simulator failures instead of filtering them out
  through a `grep` pipeline.
- Existing `sim-rx-diag`, `sim-switch-top`, `sim-sfp-port` and `sim-mac-reset`
  regressions pass after statistics wiring/source-list changes.
- All four R5 combinations of `STATS_DDR`/`STATS_DEBUG` compile and pass the
  ELF memory/vector audit. The current ELF is built with both options enabled.
- `make -C software/r5 test`: existing policy and DMA ownership tests pass;
  new statistics tests verify accumulation beyond 32 bits, maximum aggregation,
  saturation reporting, build-capability mismatch, delayed-read retry, and a stuck mailbox release.
- Vivado 2026.1 synthesized the complete board with both optional categories
  enabled, using an isolated copy under `build/r5/statistics_vivado/`.
  No synthesis errors or critical warnings. Post-synthesis use is 34,114 LUTs,
  42,476 registers and 51.5 BRAM tiles. These are synthesis figures, not routed
  utilization or a timing result.
- Out-of-context synthesis also checks the switch with both optional groups
  enabled and with both disabled; the standard netlist excludes the optional
  monitor instances. Reports are under ignored `build/reports/stats_*.rpt`.

The hard SYSMON/INA260 collector compiles against the generated BSP. The
subsequent SNMP checks above verify sensor presence and numerical readings.
Conversion freshness under faults, I2C error recovery, externally calibrated
accuracy and sustained live polling under load remain validation items,
including processor delays longer than 500 ms. See
[statistics.md](statistics.md) for measurement boundaries and counter ownership.

### All-counter implementation and firmware build

Place-and-route and bitstream generation completed on 2026-09-21 with
`STATS_DDR=1 STATS_DEBUG=1`. The implementation caught an unsupported `foreach`
in the statistics XDC; it was replaced by explicit clock-pair constraints and
implementation was restarted. The successful run has no errors or critical
warnings, and the reopened routed design has no debug/ILA cores.

Final `report_timing_summary` results: WNS **+0.018 ns**, WHS **+0.010 ns**,
TNS/THS zero, with no failing setup/hold endpoints. These final values supersede
the router's intermediate +0.016/+0.002 ns estimates. Timing passes with narrow
margins. Routed utilization is 30,692 LUTs (26.21%), 37,466 registers (15.99%)
and 51.5 BRAM tiles (35.76%). Reports are `build/reports/stats_impl_*.rpt`.

The matching R5 firmware was rebuilt with both options enabled; host tests and
ELF vector/memory checks passed. The PS peripheral map and clocks are unchanged,
so the build uses the existing generated BSP. Preserved local artifacts:

- `build/r5/statistics_artifacts/kr260_all_counters.bit`
- `build/r5/statistics_artifacts/kr260_all_counters.xsa`
- `build/r5/statistics_artifacts/kr260_statistics_r5.elf`
- `build/r5/statistics_artifacts/kr260_statistics_r5.map`
- `build/r5/statistics_artifacts/manifest.json` (options, timing, SHA-256 hashes)

The XSA's embedded bitstream was byte-compared with the generated BIT file.
Expected counter capability word is `0x53540107`. The original normal-build
project and bitstream remain separate; use the paths above for this all-counter
image.

The image and preserved matching R5 ELF were loaded through JTAG on 2026-09-21
(hw_server `10.0.1.109:3121`). UART confirmed D-cache enabled, capability word
`0x53540107` matching firmware, 250 ms statistics polling, both AMS blocks
available and PS I2C1 ready. DHCP assigned `10.0.1.214`. Concurrent full-MTU
(1472-byte payload) pings passed: R5 **100/100**, forwarded endpoint
`10.0.1.140` **50/50**. LINK_STATUS was `0x31`, PCS_STATUS `0x7`, and DMA status
was MM2S `0x1100A` / S2MM `0x11008`. This confirms basic boot/connectivity,
not numerical counter accuracy or actual sensor readings. Evidence is in
`build/r5/statistics_validation/`. No flash write was performed.


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
