# Clock-domain-crossing review

Development review recorded 2026-09-19 from an earlier post-route `report_cdc -details` of the KR260
board build (every severity, 890 rows), by tracing each crossing to its RTL and
reading the protocol. Vivado cannot prove a crossing correct; this records what
each one is, why it is (or was not) safe, and what evidence exists.

The latest inspected report (2026-09-19 13:42) has zero critical and 13 warning
clock-pair groups. It supersedes earlier summary counts, but does not make the
review below a complete sign-off of new circuitry. RGMII now uses FIFO36E2,
not the earlier generic FIFO. Vendor recognition and simulation are evidence,
not blanket waivers.

## Clocks

| Clock | Source | Nominal |
| --- | --- | --- |
| `clk_pl_0` | PS `pl_clk0` | ~142.9 MHz (MAC stream + AXI-Lite) |
| `clk_out3_pl_eth_clk_gen_ip` | PL0 MMCM | 62.5 MHz (switch fabric, all AXI masters) |
| `clk_out1_pl_eth_clk_gen_ip[_1]`, `clk_out1_sfp_pcs_clk_gen_ip` | MMCMs | 125 MHz (GMII, PCS) |
| `clk_gem{0,1}_{rx,tx}_0` | PS | 125 MHz (GEM FIFO interface, independent RX and TX) |
| `plN_rgmii_rxc` | PHY | 125 MHz (RGMII receive) |
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

## What this review does not establish

- Correctness under real, independent clock ratios and ppm drift: benches use
  fixed 2:1 or unrelated-period clocks, not measured hardware clocks.
- Metastability behavior: simulation does not model it.
- Finding 5 depends on `set_max_delay -datapath_only` staying in place and
  being met; if `kr260_clocks.xdc` is dropped or a clock is renamed, those
  paths become unchecked again.
- The RGMII receive path and the PS/GT clocks were reviewed only at the level
  above; no measurements exist.
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
- IDELAYCTRL RDY is not part of the RGMII receive reset condition. Review
  startup capture while calibration is incomplete.
