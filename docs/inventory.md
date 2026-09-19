# Design inventory and pending development

Baseline: 2026-09-19. The repository contains **56 SystemVerilog files under
`rtl/`** (52 modules, including four simulation-only behavioral models --
GTH, RGMII, PL Ethernet clock generation, and MDIO -- and four packages),
**18 testbenches**, one AXI memory BFM, three Vivado IP `.xci` configurations
(GTH, PL Ethernet clocks and SFP PCS clocks), three XDC constraint files,
three Vivado Tcl scripts, one synthesis source list and `sim/Makefile`. The inventory follows actual module instantiations and
interfaces; some source comments describe older stages of development.

The target software environment is **FreeRTOS**. Existing CPU-port comments
mention Linux socket buffers, but no Linux or FreeRTOS software is present.
The current hardware interface can be used as the starting point for a
FreeRTOS network driver.

See the [overall architecture diagrams](architecture.md) and the
[verification report](verification.md). "Present" below means source exists;
it does not mean the block is integrated on the board or production-ready.

## Source inventory

| Area | Files / modules | Implemented scope and status |
| --- | --- | --- |
| Digital switch assembly | [`switch_top.sv`](../rtl/switch_top.sv) | Joins two GEM bridges, two PL MAC ports, one SFP MAC/PCS port, physical ingress/egress, the CPU port, and MAC forwarding. Generates the aging tick (default 4 Hz at 62.5 MHz). GEM0-to-CPU smoke test passes. The board top now connects its external DDR, CPU DMA, GMII and GTH boundaries. Separate GEM RX/TX clocks replace the former single-clock interface. |
| Header parsing and forwarding | [`mac_addr_resolver.sv`](../rtl/mac_table/mac_addr_resolver.sv), [`mac_forwarding_top.sv`](../rtl/mac_table/mac_forwarding_top.sv) | Six ingress stream snoopers extract destination/source MACs, issue lookup/learning requests, and supply forwarding masks. Hits use the learned mask; misses flood all other ports (including CPU for physical ingress). Ports 6–7 of the eight-port table are unused. Basic learning/flood/short-frame tests pass; policy and error-path gaps are listed below. |
| Common logic | [`async_fifo.sv`](../rtl/common/async_fifo.sv), [`sync_fifo.sv`](../rtl/common/sync_fifo.sv), [`rr_arbiter.sv`](../rtl/common/rr_arbiter.sv), [`rst_sync.sv`](../rtl/common/rst_sync.sv) | Async-assert/synchronous-release reset helper, Gray-pointer CDC FIFO, synchronous FIFO, and round-robin arbitration. Pointer, tick and reset synchronizers now carry ASYNC_REG. Async FIFO has its own test; the new reset helper has no dedicated portable test. |
| MAC table configuration | [`mac_table_pkg.sv`](../rtl/mac_table/mac_table_pkg.sv) | Four 512-row banks, 48-bit MAC keys, eight-bit destination masks, nine-bit age, and eight learning/lookup request ports. |
| MAC table integration | [`mac_addr_table_top.sv`](../rtl/mac_table/mac_addr_table_top.sv), [`mac_table_bank.sv`](../rtl/mac_table/mac_table_bank.sv), [`bank_arbiter.sv`](../rtl/mac_table/bank_arbiter.sv) | Four-way table, bank arbitration, request FIFOs and response routing. Connected to all six ingress streams through `mac_forwarding_top`. |
| MAC learning and aging | [`mac_learn_port.sv`](../rtl/mac_table/mac_learn_port.sv), [`learn_engine_fsm.sv`](../rtl/mac_table/learn_engine_fsm.sv), [`aging_sweep_fsm.sv`](../rtl/mac_table/aging_sweep_fsm.sv) | Learns or refreshes a source-port mask, selects replacement entries, and ages entries using an external tick. Tick generation is in `switch_top`; software configuration remains external. |
| MAC lookup | [`mac_lookup_port.sv`](../rtl/mac_table/mac_lookup_port.sv), [`lookup_engine_fsm.sv`](../rtl/mac_table/lookup_engine_fsm.sv) | Queues lookup requests and returns hit/mask results using a pipelined bank read path. Connected to header extraction and miss-flood policy in `mac_addr_resolver`. |
| Shared buffer control | [`buf_mgr_pkg.sv`](../rtl/buf_mgr/buf_mgr_pkg.sv), [`buf_mgr_core.sv`](../rtl/buf_mgr/buf_mgr_core.sv), [`free_list_mgr.sv`](../rtl/buf_mgr/free_list_mgr.sv), [`queue_mgr.sv`](../rtl/buf_mgr/queue_mgr.sv) | Six-port alloc/enqueue/dequeue/release protocol, free-ID pool, reference counts, lengths, and per-port linked lists. Supports multiple destination bits for one buffer. Present and unit-tested. |
| DMA configuration | [`axi_dma_pkg.sv`](../rtl/dma/axi_dma_pkg.sv) | Five physical ports, 128-bit AXI data, 32-bit addresses, one-bit ID, and pool base `0x10000000`. |
| Physical ingress | [`ingress_top.sv`](../rtl/dma/ingress_top.sv), [`ingress_port_wr.sv`](../rtl/dma/ingress_port_wr.sv), [`ingress_dma_wr.sv`](../rtl/dma/ingress_dma_wr.sv) | Five stream receivers, local frame RAMs, shared DDR write engine, and an instantiated `buf_mgr_core`. Forwarding masks are inputs supplied by `mac_forwarding_top` in the assembled switch. Present and subsystem-tested. |
| Physical egress | [`egress_top.sv`](../rtl/dma/egress_top.sv), [`egress_port_rd.sv`](../rtl/dma/egress_port_rd.sv), [`egress_dma_rd.sv`](../rtl/dma/egress_dma_rd.sv) | Five queue consumers, shared DDR read engine, local frame RAMs, and AXI-S transmit outputs. Buffer-manager and CPU handshakes are joined in `switch_top`. Present and subsystem-tested. |
| PS GEM port | [`ps_gem_axis_bridge.sv`](../rtl/ps_eth/ps_gem_axis_bridge.sv), [`gem_rx_w_to_axis.sv`](../rtl/ps_eth/gem_rx_w_to_axis.sv), [`axis_to_gem_tx_r.sv`](../rtl/ps_eth/axis_to_gem_tx_r.sv) | One reusable full-duplex GEM FIFO/AXI-S bridge, instantiated twice in `switch_top`. Separate RX/TX clocks, RX overflow/flush bad-frame termination and TX underflow/drain/flush recovery exist. Recovery tests pass; throughput, simultaneous-event corners and real GEM timing remain open. |
| PL MAC port | [`pl_gmii_mac_top.sv`](../rtl/pl_gmii/pl_gmii_mac_top.sv), [`open_eth_mac_1g_switch.sv`](../rtl/pl_gmii/open_eth_mac_1g_switch.sv) | 1G full-duplex GMII MAC, switch-oriented receive acceptance, AXI-Lite register access, and wrapper. Instantiated twice in `switch_top`. The board wrapper joins both GMII interfaces to RGMII adapters. |
| PL MAC stream adaptation | [`mac_rxd_to_switch_ingress.sv`](../rtl/pl_gmii/mac_rxd_to_switch_ingress.sv), [`switch_egress_to_mac_txd.sv`](../rtl/pl_gmii/switch_egress_to_mac_txd.sv) | Converts 32-bit MAC data/control streams to/from the 16-bit switch streams across clock domains. Reused by the SFP port. Present and adapter-tested. |
| PL RGMII adapter | [`rgmii_gmii_adapter.sv`](../rtl/pl_gmii/rgmii_gmii_adapter.sv), [`rgmii_gmii_sim_model.sv`](../rtl/pl_gmii/rgmii_gmii_sim_model.sv) | Primitive-based DDR TX/RX conversion with optional RX clock delay and a 16-entry RX CDC FIFO. The separate behavioral model passes nibble/control loopback tests but omits the real FIFO, delay calibration, and I/O timing. The hardware module is connected to `switch_top` by `kr260_pl_top`; optional FPGA RX delay defaults off. Hardware gaps are listed below. |
| PL Ethernet constraints | [`kr260_pl_ethernet.xdc`](../constraints/kr260_pl_ethernet.xdc) | PL0 bank 66 / PL1 bank 65 package pins, LVCMOS18, and 25 MHz reference / 125 MHz RX input clocks. Targets the physical ports of `kr260_top`. External input/output timing remains incomplete; clock-crossing bounds are separate. Schematic findings and source provenance are in [board integration](board-integration.md). |
| PL Ethernet clock generation | [`pl_eth_clk_gen.sv`](../rtl/pl_gmii/pl_eth_clk_gen.sv), [`pl_eth_clk_gen_sim_model.sv`](../rtl/pl_gmii/pl_eth_clk_gen_sim_model.sv), [`pl_eth_clk_gen_ip.xci`](../rtl/pl_gmii/ip/pl_eth_clk_gen_ip.xci) | Clocking Wizard wrapper: 25 MHz input, 125/300/62.5 MHz outputs, per-domain reset release after lock. Board assembly uses two instances, with only PL0 supplying the shared 62.5 MHz fabric clock. The 300 MHz delay references are unused by default. The behavioral model passes nominal period/startup tests; local board implementation evidence is recorded separately. |
| MDIO controller | [`open_eth_mdio_master.sv`](../rtl/mdio/open_eth_mdio_master.sv), [`mdio_controller.sv`](../rtl/mdio/mdio_controller.sv), [`mdio_controller_sim_model.sv`](../rtl/mdio/mdio_controller_sim_model.sv) | Imported GPL-3.0-or-later Clause 22 engine with a new AXI-Lite register shim. Hardware wrapper uses IOBUF; portable model uses a tristate assignment. Write-frame/read-data/status-clear tests pass. Two instances in the board top connect the separate PL PHY buses and CPU register map. Register map and software requirements are in [board integration](board-integration.md#mdio-management-interface). |
| SFP PCS | [`sfp_pcs_pkg.sv`](../rtl/sfp_pcs/sfp_pcs_pkg.sv), [`sfp_1000base_x_pcs.sv`](../rtl/sfp_pcs/sfp_1000base_x_pcs.sv), [`gmii_1000base_x_tx.sv`](../rtl/sfp_pcs/gmii_1000base_x_tx.sv), [`gmii_1000base_x_rx.sv`](../rtl/sfp_pcs/gmii_1000base_x_rx.sv), [`sync_1000base_x.sv`](../rtl/sfp_pcs/sync_1000base_x.sv), [`autoneg_1000base_x.sv`](../rtl/sfp_pcs/autoneg_1000base_x.sv) | Symbol conversion, synchronization, and experimental Clause 37 base-page negotiation. Negotiation overrides TX symbols and exports informational link/duplex/pause/fault status through the SFP port and switch top. Self-loopback and two-PCS negotiation/data/recovery tests pass. Simulation timers, simplified pause/idle detection, and missing TX gating prevent treating this as a hardware-ready or fully compliant link manager. |
| SFP transceiver | [`gth_sfp_wrapper.sv`](../rtl/sfp_pcs/gth_sfp_wrapper.sv), [`gth_sfp_ip.xci`](../rtl/sfp_pcs/ip/gth_sfp_ip.xci) | Updated Transceiver Wizard configuration: X0Y6, 156.25 MHz reference, 1.25 Gb/s, 8b/10b and 16-bit user data. The reference matches the local schematic; the header records channel/pin tracing and prior Vivado synthesis. Joined to the SFP PCS by the board wrapper; earlier local reports establish routing of that assembly. Physical interoperability and clock/reset behavior remain unverified. |
| GTH behavioral model | [`gth_sfp_sim_model.sv`](../rtl/sfp_pcs/gth_sfp_sim_model.sv) | Simulation-only delayed parallel loopback with reset/status and error injection. Its standalone test passes. It does not model serial encoding, CDR, or hardware timing; existing PCS/SFP-port benches use direct parallel loopback instead of this model. |
| SFP port assembly | [`sfp_port_top.sv`](../rtl/sfp_pcs/sfp_port_top.sv) | Instantiates the PCS, imported 1G MAC, and stream adapters. Digital loopback test passes. It is a 1G design; the transceiver is deliberately a separate instantiation (the board wrapper connects it at the GTH-parallel-interface boundary). |
| CPU port | [`cpu_port_top.sv`](../rtl/cpu_port/cpu_port_top.sv), [`cpu_dma_wr.sv`](../rtl/cpu_port/cpu_dma_wr.sv), [`cpu_dma_rd.sv`](../rtl/cpu_port/cpu_dma_rd.sv) | Reuses ingress/egress front ends at port 5 and supplies dedicated switch-pool DMA engines. Stream endpoints connect to a separate CPU-facing AXI DMA SG IP in the block design. Present and subsystem-tested; firmware remains absent. |
| Board wrapper and build | [`kr260_pl_top.sv`](../rtl/board/kr260_pl_top.sv), [`kr260_top.sv`](../rtl/board/kr260_top.sv), [`sfp_pcs_clk_gen.sv`](../rtl/sfp_pcs/sfp_pcs_clk_gen.sv), [`rst_sync.sv`](../rtl/common/rst_sync.sv), [`build/`](../build/) | `kr260_pl_top` joins `switch_top` to the PHY, MDIO and transceiver interfaces; `kr260_top` connects it name-for-name to the generated block-design wrapper (Zynq PS, interconnect, CPU DMA). Local reports show routing/bitstream generation and positive slack under incomplete constraints; not tested on hardware. See [board integration](board-integration.md#board-build-and-implementation-results). |
| SFP PCS clock configuration | [`sfp_pcs_clk_gen_ip.xci`](../rtl/sfp_pcs/ip/sfp_pcs_clk_gen_ip.xci) | Third XCI: GTH 62.5 MHz to phase-related 125/62.5 MHz through one MMCM; wrapped by `sfp_pcs_clk_gen`. |
| SFP and crossing constraints | [`kr260_sfp.xdc`](../constraints/kr260_sfp.xdc), [`kr260_clocks.xdc`](../constraints/kr260_clocks.xdc) | SFP serial/reference/sideband/LED pins and implementation-only max-delay bounds between selected clock domains. External delays and CDC sign-off remain incomplete. |
| Build entry points | [`build_kr260.tcl`](../build/build_kr260.tcl), [`impl_kr260.tcl`](../build/impl_kr260.tcl), [`synth_switch_top.tcl`](../build/synth_switch_top.tcl), [`switch_top_files.f`](../build/switch_top_files.f) | PS block design, synthesis, implementation/bitstream/reports and OOC digital-switch synthesis. Generated products are ignored. Build and artifact-validation limits are documented in board integration. |

The current buffer defaults reserve 256 slots of 2048 bytes, or **512 KiB of
DDR payload storage**, starting at `0x10000000`. Metadata and local frame/FIFO
storage are additional. This address is an RTL constant, not an established
FreeRTOS memory reservation. Raising buffer counts or frame size requires
review of RAM use, burst limits, alignment, and tests.

## Modules and integration still pending

Board assembly, PS/DDR interconnect and CPU AXI DMA hardware are now present.
The following development and verification remain incomplete.

| Pending component | Required work / integration boundary |
| --- | --- |
| FreeRTOS firmware and boot flow | Initialize GEM FIFO mode and PHYs; provide DMA descriptor rings, buffer ownership/cache maintenance, interrupts and network-stack integration. Reserve the 512 KiB switch pool. No application, XSA export or boot-image packaging flow exists. |
| Management and status plane | MAC, MDIO and DMA registers plus interrupts are connected. Still needed: forwarding policy, aging configuration, link/sideband status, error/drop counters and a software driver. `default_age_i` is tied to its default; SFP status drives LEDs only. |
| PS/DDR and CPU DMA verification | HP0 carries the three switch memory interfaces; HP1 carries the CPU AXI DMA masters. Verify generated address windows, arbitration, reset behavior, sustained throughput, descriptor/cache ownership and AXI error recovery. No hardware traffic has been demonstrated. |
| PL RGMII timing and PHY setup | Board wiring exists. Configure DP83867 internal RX/TX delays (RGMII-ID), add external I/O timing constraints, validate reset requests through U19 and implement safe packet-aware RX clock adaptation. The optional FPGA RX clock-delay branch cannot be placed. |
| SFP hardware validation | Wiring, GTH and PCS clocks exist. Validate MMCM-to-GT phase, reset/receive clock correction and independent peers. Add module I2C and sideband control; LOS/MOD_ABS/TX_FAULT currently do not affect TX_DISABLE, which is tied low. |
| SFP link management | Expose hardware timer values through enclosing tops; implement compatibility/fault, idle/config stability and link-down TX admission rules. Next Page and complete asymmetric-pause resolution are absent. |
| Constraints and CDC review | Local routing/bitstream evidence exists, but complete I/O delays and CDC sign-off do not. The prior detailed report has 2,939 critical findings across 10 clock-pair groups; GEM recovery changes need fresh routed CDC analysis. Repair unsafe paths and assess FIFO/reset structures and constraint scope before accepting waivers. |
| Full-system verification | Expand the GEM0-to-CPU smoke test to all port pairs, learned unicast, flood, contention, exhaustion, reset/error recovery and sustained load through a shared memory/interconnect model. Test independent GEM RX/TX clocks; current benches tie each pair together. |

A 10G SFP path would be a separate extension: the current 1000BASE-X PCS, 1G
MAC, stream widths/rates, buffering, and memory bandwidth would all need review.

## Known gaps in existing RTL

These findings come from source review and the checks in the verification
report. The inventory preserves the source and does not resolve these gaps.

| Finding | Evidence and remaining work |
| --- | --- |
| SFP negotiation uses simulation defaults | All three timer parameters default to 8 cycles and are exposed only on `sfp_1000base_x_pcs`, not through `sfp_port_top` / `switch_top`. Set hardware timing and expose configuration before deployment. There is no negotiation-disable/fixed-link control. |
| SFP negotiation policy and TX admission | The TX mux replaces MAC symbols during negotiation without backpressure or frame-boundary coordination, so accepted traffic can be lost or truncated during bring-up/restart. `link_up_o` can assert without a mutually supported full-duplex mode and with remote-fault status set. Pause resolution is only a bitwise AND; Next Page is not exchanged. |
| SFP negotiation stability and test scope | The config-match counter retains history across invalid windows, sync loss and FSM restarts; idle detection uses PCS sync rather than checking received idle ordered sets. Review restart/stability rules. Two-PCS tests use the same RTL, clock pair and default abilities; they do not establish protocol compliance or independent-clock interoperability. |
| MDIO register contract and verification | `READ_DATA` directly exposes the master shift register: cleared on every START, updated during reads, valid for software after completion. DONE/ERROR require explicit W1C; START while busy is ignored. The divider is live during transactions. Missing tests include split AW/W timing, byte strobes, response backpressure, absent PHY/turnaround errors and busy/restart cases. |
| RGMII RX clock-rate adaptation | The hardware adapter continuously writes RX bytes and idles into a 16-entry FIFO, ignores `full_o`, and inserts an idle when empty. Nominally 125 MHz clocks can drift; there is no packet-aware idle insertion/removal or overflow recovery. Verify independent-clock traffic and prevent dropped bytes or mid-frame gaps. The behavioral RGMII model omits this FIFO. |
| RGMII timing and calibration | **Implementation found the RX clock-delay scheme illegal** (`IDELAYE3` output may not drive a BUFG), so `RX_IDELAY_ENABLE` now defaults off and the design relies on the PHY (RGMII-ID) for RX and TX delay; the PHY delay is not yet configured and margin is unverified. TX forwards an unshifted clock. No `set_input_delay` / `set_output_delay` constraints. |
| Forwarding policy is incomplete | A lookup hit is returned without removing the ingress port. The resolver learns every source address before final frame validation, with no unicast-source filter or `TUSER` input. Add same-port filtering, valid-source learning rules, explicit broadcast/multicast and CPU admission policy; VLAN-aware forwarding is absent. |
| Resolver short-frame and request handling | `TKEEP` is ignored: an 11-byte frame reaches the sixth word and issues requests using an invalid twelfth byte. Table busy outputs are unconnected, and replies are not tagged to frames. Add boundary-length tests and verify cancellation/result association after aborted frames and under request pressure. |
| GEM RX flush only partly handled | On flush, or when a byte is dropped because the FIFO is full, `gem_rx_w_to_axis` now discards the rest of the frame up to the next SOP and closes a partly-pushed frame with a synthetic error+EOP entry, so the switch sees a bad frame instead of a frame that never ends (tested). Bytes pushed before the flush are still delivered as part of that bad frame; they are not purged across the clock crossing. |
| GEM FIFO throughput is below the stated 1G goal at the current fabric clock | `axis_to_gem_tx_r` pushes one byte per fabric cycle, so at 62.5 MHz it fills its FIFO at 500 Mb/s while the GEM can pull 1 Gb/s. With the underflow handling below, **a frame longer than what is buffered will now be aborted mid-frame on real hardware** (underflow, drain, flush) rather than hanging, until the fill rate/width is reworked (e.g. a 16-bit-wide FIFO, or starting the GEM read only once enough of the frame is buffered). RX also drains a byte-wide FIFO in the fabric domain. The existing short-frame tests do not establish line rate. |
| GEM TX start policy still incomplete | `tx_r_data_rdy_o` asserts whenever the FIFO is non-empty rather than when enough of the frame is buffered. An empty FIFO mid-frame is now handled per UG1085: `tx_r_underflow_o` answers the read, the rest of the frame is drained, `tx_r_flushed_o` pulses, and `tx_r_data_rdy_o` returns afterwards (tested in `tb_ps_gem_axis_bridge.sv` test F). `tx_r_err_o` and `tx_r_control_o` are still tied low, `tx_r_status_i` is not consumed (only acknowledged), and half-duplex collision retries are not handled. |
| GEM FIFO clock and status contract | The bridge and board wrapper now use separate GEM RX/TX clocks with per-domain resets. The latest RX recovery change removes the unsynchronized FIFO-empty dependency and clears overflow after GEM-domain frame completion. Both portable benches still tie RX/TX clocks together. Confirm real GEM byte width/configuration and status timing: raw `rx_w_status_o` remains GEM-domain data, unaligned with fabric TLAST. |
| Frame-size and stream-contract enforcement | `ingress_port_wr` assumes frames fit the 2048-byte slot and accepts only its documented keep patterns; no explicit overlength drain/drop path is present. Its error decision samples `TUSER` on the final transfer. Define malformed-stream handling and enforce limits at every ingress, including CPU. |
| AXI error responses are ignored | Physical and CPU DMA engines explicitly do not check `BRESP` / `RRESP`. Add error propagation and recovery that preserves queue/refcount ownership. |
| Sustained traffic and slow destinations are unproven | Front ends hold one frame at a time; physical DMA engines serialize frame transfers. The shared pool has no completed per-egress admission/quota policy. Measure throughput and add buffering/drop policies so congested outputs or CPU capture cannot exhaust the pool indefinitely. |
| Existing lint warnings | `lint-pl-gmii`, `lint-sfp-port`, and `lint-switch-top` fail with 31, 37, and 61 warnings respectively under Verilator 5.020. Width expansion/truncation in the imported MAC, mixed timescales, and the `interrupt` symbol require review. |
| System synthesis and CDC are only partly verified | Local reports show routing and positive slack under the current constraints, with missing external I/O delays. The detailed CDC report lists 2,042 CDC-1, 896 CDC-13 and one CDC-14 critical findings, grouped into 10 critical clock pairs in the summary. These older reports include FIFO storage paths and the former unsynchronized GEM overflow-clear control path, removed by the latest RX changes. A fresh routed report for the updated RTL remains needed. Whole-domain max-delay bounds limit delay, not protocol correctness or independently specified bus skew. ASYNC_REG is present on selected synchronizers; do not assume all findings are benign. See [verification evidence](verification.md#local-vivado-implementation-evidence). |
| Test failures do not reliably fail the process | Existing benches print failures and call `$finish`. CI needs explicit fatal exits or a runner that checks failure and final-pass markers. |

## Board evidence and integration boundary

The local XTP743 schematic identifies TI DP83867CSRGZ PL PHYs, a shared
25 MHz oscillator/buffer for both FPGA reference inputs and both PHYs, and
reset requests routed through U19. It also identifies the 156.25 MHz SFP
reference now selected by the GTH IP. See [board integration](board-integration.md) for sheet references,
revision limits, clock diagram, and the vendor-source download information.

## Historical comments to reconcile

- `ingress_top` / `egress_top` call the CPU interface a future module, but
  `cpu_port_top` now exists and is connected to their passthrough ports in `switch_top`.
- `buf_mgr_core` describes an older CPU path that skips DMA; the actual
  `cpu_port_top` uses two dedicated DMA engines.
- `axi_dma_pkg` and `cpu_port_top` describe Linux buffers. The intended OS for
  this project is FreeRTOS, and its software integration remains to be written.
- `mac_forwarding_top` still describes `switch_top` as absent, though the
  table and all six resolvers are now instantiated by that top level. Resolver
  comments also overstate source-address validation and short-frame handling;
  see the findings above.
- The RGMII adapter header still says no IDELAY reference source exists;
  the board clock generators provide 300 MHz outputs, but the default
  adapters disable the unplaceable FPGA RX clock-delay path.
- The XDC footer says the ports have no shared reference, contradicting its
  own schematic-derived header. Shared oscillator inputs do not establish
  synchronous timing through separate MMCMs or PHY receive paths.
- The clock-generator header claims separate I/O banks make clock sharing
  impossible. The two-generator arrangement is a design choice;
  bank-local delay calibration alone does not establish that restriction.
- The MDIO header describes a latched last-read result, but `READ_DATA`
  exposes the master shift register. Its divider 100 gives about 742.6 kHz
  at 150 MHz (division by 202), rather than exactly 750 kHz; the actual
  PS clock near 142.857 MHz gives about 707.2 kHz. The MDIO
  testbench uses a 125 MHz clock despite a 150 MHz comment.
- The negotiation header says half-duplex is never advertised; it is actually
  parameter-selectable, though disabled by default and unsupported by the MAC.
  Source comments report external protocol cross-checks, not conformance proof.
- The build header still describes a block-design module reference; the actual
  flow generates external BD ports joined by the static `kr260_top` wrapper.
- Several headers describe Icarus 12.0 workarounds. The checked-in baseline
  was freshly simulated with 13.0; no claim is made here about the root cause
  of those historical issues.

## Suggested development order

1. Harden forwarding policy and resolver error paths; expand the integrated
   tests to learned unicast, concurrent ports, and a real shared AXI memory model.
2. Resolve GEM streaming/abort behavior, frame limits, and DMA error handling;
   add sustained-traffic and recovery tests.
3. Complete I/O constraints and CDC/reset review; harden RGMII clock adaptation
   and SFP negotiation before attempting traffic on hardware.
4. Implement management and FreeRTOS drivers/boot packaging, then verify PS/DDR,
   CPU DMA and all physical ports on the board.
