# Design inventory and pending development

Baseline: 2026-09-18. The repository contains **52 SystemVerilog files under
`rtl/`** (48 modules, including four simulation-only behavioral models --
GTH, RGMII, PL Ethernet clock generation, and MDIO -- and four packages),
**18 testbenches**, one AXI memory BFM, two Vivado IP `.xci` configurations
(the SFP GTH transceiver and the PL Ethernet clock generator), one
board-derived pin constraints file (`constraints/kr260_pl_ethernet.xdc`), and
`sim/Makefile`. The inventory follows actual module instantiations and
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
| Digital switch assembly | [`switch_top.sv`](../rtl/switch_top.sv) | Joins two GEM bridges, two PL MAC ports, one SFP MAC/PCS port, physical ingress/egress, the CPU port, and MAC forwarding. Generates the aging tick (default 4 Hz at 62.5 MHz). GEM0-to-CPU smoke test passes. PS DDR, CPU-facing DMA, GTH wrapper, and board integration remain external. |
| Header parsing and forwarding | [`mac_addr_resolver.sv`](../rtl/mac_table/mac_addr_resolver.sv), [`mac_forwarding_top.sv`](../rtl/mac_table/mac_forwarding_top.sv) | Six ingress stream snoopers extract destination/source MACs, issue lookup/learning requests, and supply forwarding masks. Hits use the learned mask; misses flood all other ports (including CPU for physical ingress). Ports 6–7 of the eight-port table are unused. Basic learning/flood/short-frame tests pass; policy and error-path gaps are listed below. |
| Common logic | [`async_fifo.sv`](../rtl/common/async_fifo.sv), [`sync_fifo.sv`](../rtl/common/sync_fifo.sv), [`rr_arbiter.sv`](../rtl/common/rr_arbiter.sv) | Gray-pointer CDC FIFO, synchronous FIFO, and round-robin arbitration. Present; async FIFO has its own test, others are exercised through subsystem tests. |
| MAC table configuration | [`mac_table_pkg.sv`](../rtl/mac_table/mac_table_pkg.sv) | Four 512-row banks, 48-bit MAC keys, eight-bit destination masks, nine-bit age, and eight learning/lookup request ports. |
| MAC table integration | [`mac_addr_table_top.sv`](../rtl/mac_table/mac_addr_table_top.sv), [`mac_table_bank.sv`](../rtl/mac_table/mac_table_bank.sv), [`bank_arbiter.sv`](../rtl/mac_table/bank_arbiter.sv) | Four-way table, bank arbitration, request FIFOs and response routing. Connected to all six ingress streams through `mac_forwarding_top`. |
| MAC learning and aging | [`mac_learn_port.sv`](../rtl/mac_table/mac_learn_port.sv), [`learn_engine_fsm.sv`](../rtl/mac_table/learn_engine_fsm.sv), [`aging_sweep_fsm.sv`](../rtl/mac_table/aging_sweep_fsm.sv) | Learns or refreshes a source-port mask, selects replacement entries, and ages entries using an external tick. Tick generation is in `switch_top`; software configuration remains external. |
| MAC lookup | [`mac_lookup_port.sv`](../rtl/mac_table/mac_lookup_port.sv), [`lookup_engine_fsm.sv`](../rtl/mac_table/lookup_engine_fsm.sv) | Queues lookup requests and returns hit/mask results using a pipelined bank read path. Connected to header extraction and miss-flood policy in `mac_addr_resolver`. |
| Shared buffer control | [`buf_mgr_pkg.sv`](../rtl/buf_mgr/buf_mgr_pkg.sv), [`buf_mgr_core.sv`](../rtl/buf_mgr/buf_mgr_core.sv), [`free_list_mgr.sv`](../rtl/buf_mgr/free_list_mgr.sv), [`queue_mgr.sv`](../rtl/buf_mgr/queue_mgr.sv) | Six-port alloc/enqueue/dequeue/release protocol, free-ID pool, reference counts, lengths, and per-port linked lists. Supports multiple destination bits for one buffer. Present and unit-tested. |
| DMA configuration | [`axi_dma_pkg.sv`](../rtl/dma/axi_dma_pkg.sv) | Five physical ports, 128-bit AXI data, 32-bit addresses, one-bit ID, and pool base `0x10000000`. |
| Physical ingress | [`ingress_top.sv`](../rtl/dma/ingress_top.sv), [`ingress_port_wr.sv`](../rtl/dma/ingress_port_wr.sv), [`ingress_dma_wr.sv`](../rtl/dma/ingress_dma_wr.sv) | Five stream receivers, local frame RAMs, shared DDR write engine, and an instantiated `buf_mgr_core`. Forwarding masks are inputs supplied by `mac_forwarding_top` in the assembled switch. Present and subsystem-tested. |
| Physical egress | [`egress_top.sv`](../rtl/dma/egress_top.sv), [`egress_port_rd.sv`](../rtl/dma/egress_port_rd.sv), [`egress_dma_rd.sv`](../rtl/dma/egress_dma_rd.sv) | Five queue consumers, shared DDR read engine, local frame RAMs, and AXI-S transmit outputs. Buffer-manager and CPU handshakes are joined in `switch_top`. Present and subsystem-tested. |
| PS GEM port | [`ps_gem_axis_bridge.sv`](../rtl/ps_eth/ps_gem_axis_bridge.sv), [`gem_rx_w_to_axis.sv`](../rtl/ps_eth/gem_rx_w_to_axis.sv), [`axis_to_gem_tx_r.sv`](../rtl/ps_eth/axis_to_gem_tx_r.sv) | One reusable full-duplex GEM FIFO/AXI-S bridge, instantiated twice in `switch_top`. Width conversion and CDC exist; flush, overflow recovery, throughput, and real GEM timing need further work. |
| PL MAC port | [`pl_gmii_mac_top.sv`](../rtl/pl_gmii/pl_gmii_mac_top.sv), [`open_eth_mac_1g_switch.sv`](../rtl/pl_gmii/open_eth_mac_1g_switch.sv) | 1G full-duplex GMII MAC, switch-oriented receive acceptance, AXI-Lite register access, and wrapper. Instantiated twice in `switch_top`. RGMII board interface exists separately (see below) but isn't joined in. |
| PL MAC stream adaptation | [`mac_rxd_to_switch_ingress.sv`](../rtl/pl_gmii/mac_rxd_to_switch_ingress.sv), [`switch_egress_to_mac_txd.sv`](../rtl/pl_gmii/switch_egress_to_mac_txd.sv) | Converts 32-bit MAC data/control streams to/from the 16-bit switch streams across clock domains. Reused by the SFP port. Present and adapter-tested. |
| PL RGMII adapter | [`rgmii_gmii_adapter.sv`](../rtl/pl_gmii/rgmii_gmii_adapter.sv), [`rgmii_gmii_sim_model.sv`](../rtl/pl_gmii/rgmii_gmii_sim_model.sv) | Primitive-based DDR TX/RX conversion with optional RX clock delay and a 16-entry RX CDC FIFO. The separate behavioral model passes nibble/control loopback tests but omits the real FIFO, delay calibration, and I/O timing. Neither module is connected to `switch_top`; hardware gaps are listed below. |
| PL Ethernet constraints | [`kr260_pl_ethernet.xdc`](../constraints/kr260_pl_ethernet.xdc) | PL0 bank 66 / PL1 bank 65 package pins, LVCMOS18, and 25 MHz reference / 125 MHz RX input clocks. Targets a future board wrapper, not the current `switch_top` port names. No complete external input/output timing or CDC constraint set. Schematic findings and source provenance are in [board integration](board-integration.md). |
| PL Ethernet clock generation | [`pl_eth_clk_gen.sv`](../rtl/pl_gmii/pl_eth_clk_gen.sv), [`pl_eth_clk_gen_sim_model.sv`](../rtl/pl_gmii/pl_eth_clk_gen_sim_model.sv), [`pl_eth_clk_gen_ip.xci`](../rtl/pl_gmii/ip/pl_eth_clk_gen_ip.xci) | Clocking Wizard wrapper: 25 MHz input, 125/300/62.5 MHz outputs, per-domain reset release after lock. Proposed assembly uses two instances, with only PL0 supplying the shared 62.5 MHz fabric clock. The behavioral model passes nominal period/startup tests; board wiring remains pending. Prior isolated Vivado synthesis is reported in source comments, not reproduced by this inventory. |
| MDIO controller | [`open_eth_mdio_master.sv`](../rtl/mdio/open_eth_mdio_master.sv), [`mdio_controller.sv`](../rtl/mdio/mdio_controller.sv), [`mdio_controller_sim_model.sv`](../rtl/mdio/mdio_controller_sim_model.sv) | Imported GPL-3.0-or-later Clause 22 engine with a new AXI-Lite register shim. Hardware wrapper uses IOBUF; portable model uses a tristate assignment. Write-frame/read-data/status-clear tests pass. Intended as two instances for the separate PL PHY buses; not instantiated in the switch or board top. Register map and software requirements are in [board integration](board-integration.md#mdio-management-interface). |
| SFP PCS | [`sfp_pcs_pkg.sv`](../rtl/sfp_pcs/sfp_pcs_pkg.sv), [`sfp_1000base_x_pcs.sv`](../rtl/sfp_pcs/sfp_1000base_x_pcs.sv), [`gmii_1000base_x_tx.sv`](../rtl/sfp_pcs/gmii_1000base_x_tx.sv), [`gmii_1000base_x_rx.sv`](../rtl/sfp_pcs/gmii_1000base_x_rx.sv), [`sync_1000base_x.sv`](../rtl/sfp_pcs/sync_1000base_x.sv), [`autoneg_1000base_x.sv`](../rtl/sfp_pcs/autoneg_1000base_x.sv) | Symbol conversion, synchronization, and experimental Clause 37 base-page negotiation. Negotiation overrides TX symbols and exports informational link/duplex/pause/fault status through the SFP port and switch top. Self-loopback and two-PCS negotiation/data/recovery tests pass. Simulation timers, simplified pause/idle detection, and missing TX gating prevent treating this as a hardware-ready or fully compliant link manager. |
| SFP transceiver | [`gth_sfp_wrapper.sv`](../rtl/sfp_pcs/gth_sfp_wrapper.sv), [`gth_sfp_ip.xci`](../rtl/sfp_pcs/ip/gth_sfp_ip.xci) | Updated Transceiver Wizard configuration: X0Y6, 156.25 MHz reference, 1.25 Gb/s, 8b/10b and 16-bit user data. The reference matches the local schematic; the header records channel/pin tracing and prior Vivado synthesis. Those vendor-tool checks were not rerun here. Wrapper remains separate from `switch_top`; generated IP, placement/clock/reset integration and hardware validation remain pending. |
| GTH behavioral model | [`gth_sfp_sim_model.sv`](../rtl/sfp_pcs/gth_sfp_sim_model.sv) | Simulation-only delayed parallel loopback with reset/status and error injection. Its standalone test passes. It does not model serial encoding, CDR, or hardware timing; existing PCS/SFP-port benches use direct parallel loopback instead of this model. |
| SFP port assembly | [`sfp_port_top.sv`](../rtl/sfp_pcs/sfp_port_top.sv) | Instantiates the PCS, imported 1G MAC, and stream adapters. Digital loopback test passes. It is a 1G design; the transceiver is deliberately a separate instantiation (neither this module nor `switch_top.sv` joins it -- both stop at the GTH-parallel-interface boundary, per their own headers). |
| CPU port | [`cpu_port_top.sv`](../rtl/cpu_port/cpu_port_top.sv), [`cpu_dma_wr.sv`](../rtl/cpu_port/cpu_dma_wr.sv), [`cpu_dma_rd.sv`](../rtl/cpu_port/cpu_dma_rd.sv) | Reuses ingress/egress front ends at port 5 and supplies dedicated switch-pool DMA engines. Stream endpoints are ready for a separate CPU-facing AXI DMA IP. Present and subsystem-tested; that IP and its software are absent. |

The current buffer defaults reserve 256 slots of 2048 bytes, or **512 KiB of
DDR payload storage**, starting at `0x10000000`. Metadata and local frame/FIFO
storage are additional. This address is an RTL constant, not an established
FreeRTOS memory reservation. Raising buffer counts or frame size requires
review of RAM use, burst limits, alignment, and tests.

## Modules and integration still pending

The digital switch assembly and basic forwarding pipeline now exist. The
following functions or integration steps are still incomplete.

| Pending component | Required work / integration boundary |
| --- | --- |
| PS/DDR AXI integration | Connect physical and CPU read/write masters through a suitable interconnect to PS DDR; define HP/HPC interfaces, reset domains, arbitration, and a reserved memory map. |
| CPU-facing AXI DMA SG | Instantiate/configure vendor DMA for 16-bit packet streams, descriptor access, software-owned data buffers, and interrupts. This is separate from the existing `cpu_dma_*` switch-pool engines. |
| FreeRTOS firmware | Implement GEM FIFO-mode and PHY initialization, DMA rings, cache maintenance, interrupt handling, network-stack input/output, and buffer ownership. No software directory or application build exists. |
| Management and status plane | Wire MAC AXI-Lite interfaces; provide forwarding configuration, aging tick/default-age controls, link status, drop/error counters, and CPU register/interrupt access. |
| PL RGMII board assembly | Join two RGMII adapters, the proposed two clock generators, and the two MDIO controllers (see rows above) to `switch_top` in a board wrapper. Add PHY reset-request control, explicit DP83867 delay configuration, reset/calibration sequencing, and full timing/CDC constraints. The current MAC path supports 1G full duplex only. |
| SFP hardware assembly | Join the updated GTH wrapper to the switch and regenerate vendor output products. Validate generated placement/reference-clock constraints, RX control mapping and clock correction. Generate and constrain the related 125/62.5 MHz PCS clocks and reset sequencing. |
| SFP link management | Finish the experimental negotiation implementation: hardware timer values exposed through the enclosing tops, full-duplex compatibility/fault policy, idle/config stability rules, and transmit admission while link is down or restarting. Validate against independent implementations and real peers; Next Page and complete asymmetric-pause resolution are absent. |
| Board build and constraints | Add reproducible Vivado project/IP-generation Tcl, target settings, XPM support, board wrapper, clock/reset integration, full timing/CDC constraints and bitstream build. PL pin/input-clock constraints exist; SFP IP settings are updated, but generated constraints, complete clock routing and physical implementation still need verification. |
| Full-system verification | Extend the GEM0-to-CPU smoke test to learned unicast and all port combinations using a shared AXI memory/interconnect model; add contention, flood, exhaustion, reset/error recovery and sustained-load tests, then synthesis/timing and board bring-up. |

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
| RGMII timing and calibration | TX forwards an unshifted clock; RX defaults to a 700 ps clock delay. The PHY delay settings and PCB timing budget are not established. `IDELAYCTRL.RDY` is unused; calibration readiness and reset pulse requirements must gate receive operation. Current XDC has no `set_input_delay` / `set_output_delay` constraints. |
| Forwarding policy is incomplete | A lookup hit is returned without removing the ingress port. The resolver learns every source address before final frame validation, with no unicast-source filter or `TUSER` input. Add same-port filtering, valid-source learning rules, explicit broadcast/multicast and CPU admission policy; VLAN-aware forwarding is absent. |
| Resolver short-frame and request handling | `TKEEP` is ignored: an 11-byte frame reaches the sixth word and issues requests using an invalid twelfth byte. Table busy outputs are unconnected, and replies are not tagged to frames. Add boundary-length tests and verify cancellation/result association after aborted frames and under request pressure. |
| GEM RX flush does not discard all in-flight data | `gem_rx_w_to_axis` explicitly documents that flush suppresses later bytes but does not purge bytes already crossing the FIFO or held by the packer. Add a cross-domain abort/flush protocol and verify recovery into the next frame. The current flush test checks suppression, not recovery. |
| GEM FIFO throughput is below the stated 1G goal at the proposed fabric clock | `axis_to_gem_tx_r` pushes one byte per fabric cycle, taking two cycles for a full 16-bit word. At 62.5 MHz this caps its FIFO fill bandwidth at 500 Mb/s before other stalls. RX also drains a byte-wide FIFO in the fabric domain. Rework widths/clocking and test uninterrupted 1G traffic; the existing short-frame tests do not establish line rate. |
| GEM TX start and error recovery are incomplete | `tx_r_data_rdy_o` asserts whenever the FIFO is nonempty, rather than when a complete frame or sufficient guaranteed data is available. Underflow/error/flushed outputs are tied low, and status is acknowledged without recovery. Add a safe start policy and recovery sequencing. |
| Real GEM clock/interface assumptions need validation | The wrapper exposes a single `gem_clk` for RX and TX and an eight-bit RX data port. Confirm actual generated PS ports, byte validity, and RX/TX clocks against the target configuration. `rx_w_status_o` remains in the GEM domain and is not aligned with the fabric `TLAST`. |
| Frame-size and stream-contract enforcement | `ingress_port_wr` assumes frames fit the 2048-byte slot and accepts only its documented keep patterns; no explicit overlength drain/drop path is present. Its error decision samples `TUSER` on the final transfer. Define malformed-stream handling and enforce limits at every ingress, including CPU. |
| AXI error responses are ignored | Physical and CPU DMA engines explicitly do not check `BRESP` / `RRESP`. Add error propagation and recovery that preserves queue/refcount ownership. |
| Sustained traffic and slow destinations are unproven | Front ends hold one frame at a time; physical DMA engines serialize frame transfers. The shared pool has no completed per-egress admission/quota policy. Measure throughput and add buffering/drop policies so congested outputs or CPU capture cannot exhaust the pool indefinitely. |
| Existing lint warnings | `lint-pl-gmii`, `lint-sfp-port`, and `lint-switch-top` fail with 31, 37, and 61 warnings respectively under Verilator 5.020. Width expansion/truncation in the imported MAC, mixed timescales, and the `interrupt` symbol require review. |
| System synthesis and CDC remain unverified | Source comments report isolated RGMII/clock-generator Vivado checks, but no reproducible scripts or reports are committed. These do not establish whole-switch synthesis, MAC XPM behavior, placement/routing, CDC/reset correctness, timing closure, or hardware operation. |
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
  `pl_eth_clk_gen` now supplies a proposed 300 MHz source, pending assembly.
- The XDC footer says the ports have no shared reference, contradicting its
  own schematic-derived header. Shared oscillator inputs do not establish
  synchronous timing through separate MMCMs or PHY receive paths.
- The clock-generator header claims separate I/O banks make clock sharing
  impossible. The proposed two-generator arrangement is a design choice;
  bank-local delay calibration alone does not establish that restriction.
- The MDIO header describes a latched last-read result, but `READ_DATA`
  exposes the master shift register. Its divider 100 gives about 742.6 kHz
  at 150 MHz (division by 202), rather than exactly 750 kHz. The MDIO
  testbench uses a 125 MHz clock despite a 150 MHz comment.
- The negotiation header says half-duplex is never advertised; it is actually
  parameter-selectable, though disabled by default and unsupported by the MAC.
  Source comments report external protocol cross-checks, not conformance proof.
- Several headers describe Icarus 12.0 workarounds. The checked-in baseline
  was freshly simulated with 13.0; no claim is made here about the root cause
  of those historical issues.

## Suggested development order

1. Harden forwarding policy and resolver error paths; expand the integrated
   tests to learned unicast, concurrent ports, and a real shared AXI memory model.
2. Resolve GEM streaming/abort behavior, frame limits, and DMA error handling;
   add sustained-traffic and recovery tests.
3. Add PS/DDR and CPU DMA integration, management registers, and FreeRTOS software.
4. Complete physical RGMII/GTH integration, clock/reset constraints, synthesis,
   timing closure, and hardware tests.
