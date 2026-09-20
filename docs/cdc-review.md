# Clock-domain-crossing review

Development review recorded 2026-09-19 from an earlier post-route `report_cdc -details` of the KR260
board build (every severity, 890 rows), by tracing each crossing to its RTL and
reading the protocol. Vivado cannot prove a crossing correct; this records what
each one is, why it is (or was not) safe, and what evidence exists.

The latest inspected report (2026-09-19 20:42) has zero critical and 13 warning
clock-pair groups. It supersedes earlier summary counts, but does not make the
review below a complete sign-off of new circuitry. RGMII now uses FIFO36E2,
not the earlier generic FIFO. Vendor recognition and simulation are evidence,
not blanket waivers.

## Clocks

| Clock | Source | Nominal |
| --- | --- | --- |
| `clk_pl_0` | PS `pl_clk0` | ~142.9 MHz (MAC stream + AXI-Lite) |
| `clk_out3_pl_eth_clk_gen_ip` | PL0 MMCM | 100 MHz (switch fabric, all AXI masters) |
| `clk_out1_pl_eth_clk_gen_ip[_1]`, `clk_out1_sfp_pcs_clk_gen_ip` | MMCMs | 125 MHz (GMII, PCS) |
| `clk_gem{0,1}_{rx,tx}_0` | PS | 125 MHz (GEM FIFO interface, independent RX and TX) |
| `plN_rgmii_rxc` | PHY | 125 MHz (RGMII receive; also the write clock of the elastic buffer) |
| `clk_pl_1`, GT clocks | PS / GTH | 50 MHz freerun, 62.5 MHz user clocks |

## Findings

| # | Crossing | Tool rows | Verdict |
| --- | --- | --- | --- |
| 1 | MAC **data read pointers** (`tx_data_rd_gray`, `rx_data_rd_gray`) | CDC-6 | **Defect, fixed.** They were published after jumps of a whole frame's words, so several Gray bits changed at once; the other domain decodes the sampled value to compute free buffer space, and a mid-transition sample could report space that is not free yet (overwriting unread transmit or receive data). Now published one word per clock. |
| 2 | MAC descriptor pointers (`tx/rx_desc_{wr,rd}_gray`) | CDC-6 | Conditional: each steps by one. Physical pointer-bit skew, synchronizer placement and reset behavior must also satisfy the CDC contract. |
| 3 | TX start-permit counter (GEM TX bridge) | CDC-6 | Conditional: at most one increment per fabric clock (one write per cycle, at most one permit per write), so the Gray code changes at most one bit. Physical skew/reset assumptions still need to hold; the RTL monitor checks logical transitions only. |
| 4 | XPM async FIFOs: GEM RX/TX bridges (x2), MAC stream adapters (x3 MACs, RX and TX) | CDC-15 (771), CDC-3, CDC-9 | Vendor structure, safe by XPM construction. CDC-15 is the FIFO memory to read-register path, which relies on the FIFO's own pointer protocol. Waivable as vendor-owned. |
| 5 | MAC descriptor fields and `snapshot_value`/`snapshot_select` | CDC-15 | Data-before-flag: the multi-bit data is written before the Gray pointer or handshake flag that publishes it, and read only after that flag has crossed a 2-flop synchronizer. Safe **provided** the data path delay stays below the synchronizer latency (about 2 destination clocks, >= 14 ns); `kr260_clocks.xdc` bounds those paths to 7 ns and timing is met. Load-bearing on that constraint. |
| 6 | MAC single-bit controls (TX/RX enable, `snapshot_request`, `snapshot_ack`) | CDC-3 | Safe: two-flop synchronizers with `ASYNC_REG`, levels held until acknowledged (four-phase handshake for the counter snapshot). |
| 7 | MAC reset reclocking | CDC-3 | Reviewed structure: each reset input has its own async-assert/sync-release synchronizer per domain; GMII-domain resets come from registered launch flops, one per synchronizer (the earlier CDC-11 fan-out finding). |
| 8 | Reset synchronizers in the board wrapper and RGMII adapter | CDC-9 | Safe: async-assert/sync-release with `ASYNC_REG`. |
| 9 | SmartConnect AXI clock converter to the DMA control port; AXI DMA register module | CDC-3, CDC-6 | Vendor IP, waivable. |
| 10 | GTH wizard calibration/monitor logic (freerun clock vs GT clocks) | CDC-3, CDC-9, CDC-15 | Vendor IP, waivable. |
| 11 | RGMII receive elastic buffer (`rgmii_rx_elastic.sv`): hard `FIFO36E2` (2048 x 18) between `plN_rgmii_rxc` and the 125 MHz GMII clock, x2 | none reported (the crossing is internal to the primitive) | Safe by construction of the hard FIFO (its own Gray pointers); its use is the risk, not the crossing. The design uses the FIFO's per-side counts (`EXTENDED_DATACOUNT`) to add/drop idle only between frames and to hold a 64-word cushion before a frame; overflow/underrun raise events. The write side reads the write-domain count and the read side the read-domain count, never the other side's. |
| 12 | Sticky diagnostics (`sticky_xdomain.sv`): overflow set in the receive-clock domain, underrun in the 125 MHz domain, read and cleared from `clk_pl_0` | CDC-3 (1 endpoint per pair) | Safe: the flag is a single sticky bit crossing by a 2-flop `ASYNC_REG` synchronizer; the clear is a toggle synchronized the other way, with edge detection in the source domain. Events in the few source cycles before the clear arrives are lost, and a clear waits while the source clock is stopped: documented behavior, not a hazard. Needed new `set_max_delay` pairs (receive clock <-> `clk_pl_0`); without them the first build failed timing by 0.86 ns. |
| 13 | SFP sideband (`sfp_sideband.sv`) | Info (input port clock) | The three input pins go through 2-flop `ASYNC_REG` synchronizers and ms-scale debouncing; TX_DISABLE is a registered static level; the pins carry `set_false_path`. Safe for slow signals. |
| 14 | SFP PCS gearbox (125 MHz <-> 62.5 MHz) | "Safely Timed" | Not an asynchronous crossing: both clocks come from the same MMCM and the width converter relies on their phase relationship. Static timing checks it; nothing checks that the phase assumption holds on hardware. |

## Evidence

- **Finding 1** is a genuine failure, not a tool artifact: the new monitor in
  `tb_sfp_port_top.sv` reports every MAC Gray pointer that changes more than
  one bit at once. On the unmodified core it flagged exactly `tx_data_rd` and
  `rx_data_rd` (2 updates each across two frames) and none of the descriptor
  pointers; after the fix it reports none. A new stress test sends 20
  back-to-back 600-byte frames (about 12 KB, three times the 4 KB transmit
  buffer) through the recycled buffers and checks every frame in order.
- **Finding 3** is checked by a monitor in `tb_ps_gem_axis_bridge.sv`
  (in Icarus and in Vivado xsim with XPM).
- **Finding 4** is exercised in xsim by the `xsim-*-xpm` targets; in Icarus and
  Verilator the FIFO is a behavioral model.
- The MAC reset reclocking has its own bench (`tb_mac_reset_reclock.sv`).
- **Finding 11**: `tb_rgmii_rx_elastic.sv` offsets the two clocks by 0, +-500 and
  +-3000 ppm with 250 random back-to-back frames each; every frame is identical
  in order, the output gap never drops below 8, idle status data is preserved and
  no flag is raised (Icarus with the behavioral model; xsim with the real
  `FIFO36E2` model at +500, +3000 and -3000 ppm). A mutation that removes the
  read cushion truncates frames and raises underrun. Place-and-route DRC also
  rejected one configuration (`SIMPLE_DATACOUNT` with independent clocks) that
  simulation had accepted.
- **Finding 12**: `tb_rx_diag.sv` uses unrelated clocks: set, hold across reads,
  clear of one bit only, write of 0 ignored, re-set after clear.
- **Finding 13**: `tb_sfp_sideband.sv` (scaled timers); a mutation that never
  gates the laser fails 8 checks.

## What this review does not establish

- Correctness under real, independent clock ratios and ppm drift: benches use
  fixed 2:1 or unrelated-period clocks, not measured hardware clocks.
- Metastability behavior: simulation does not model it.
- Finding 5 depends on `set_max_delay -datapath_only` staying in place and
  being met; if `kr260_clocks.xdc` is dropped or a clock is renamed, those
  paths become unchecked again.
- The RGMII receive path and the PS/GT clocks were reviewed only at the level
  above; no measurements exist, and the elastic buffer has not been run against
  real PHY clocks (simulated offsets reach +-3000 ppm, real crystals differ by
  tens of ppm).
- The hard FIFO's crossing does not appear in `report_cdc`, so it has no
  independent tool check here.
- I did not review the AXI SmartConnect, AXI DMA or GTH wizard internals; they
  are vendor-owned and are treated as such.

## Additions requiring continued review

- RGMII elastic storage now uses `fifo36_async_2kx18` / FIFO36E2 with extended
  counts. The +500 ppm vendor-model test checks ordering and gaps; overflow,
  underrun and reset/clock-stop combinations remain open.
- `sticky_xdomain` synchronizes source sticky levels and sends clear toggles
  back without acknowledgement. The 16-cycle read mask can hide recent events;
  rapid clears and stopped source clocks need explicit protocol checks.
- PHY reset-request release is synchronized into the MDIO controller clock;
  verify initialization startup/restart when clocks or resets disappear.
- SFP pins use two-flop synchronization and timed debounce in `sfp_sideband`.
  False-path constraints on slow pins do not validate debounce or fault timing.
- `async_fifo` ignores read-side reset in its synthesis branch. Audit every
  instantiation against the write-side-reset contract, including clock loss.
- IDELAYCTRL RDY now crosses through two flops and a receive-clock hold counter
  before RX reset release. A primitive-model bench verifies release order,
  at least 64 clocks of hold and re-reset. Stopped clocks, bank replicas and
  board behavior remain unverified.

## Port-link control and polling additions

`port_link_ctrl` synchronizes software levels and flush toggles into the
100 MHz fabric. A four-cycle delay separates link masking from the flush
pulse. Queue and MAC-table engines merge pending masks, and their combined
busy status is registered before synchronization back to AXI-Lite. Tests cover
queue/refcount release races, multiple flushes, learned-entry expiry and a
switch CPU-port down/up sequence.

There is no per-command acknowledgement: rapid repeated toggles can coalesce,
and busy is initially low while a request crosses domains. Re-enabling a port
before a flush finishes and continued source learning need explicit policy.
The MDIO poller and link-event register share the control clock, while SFP
negotiation link passes through a two-flop synchronizer before event detection.
The new clock plan and constraints require review of all physical skew/reset
assumptions; fixed-ratio simulation does not prove metastability safety.
