# Design inventory and pending development

Baseline: 2026-09-17. The repository contains **39 SystemVerilog RTL files**
(35 modules and four packages), **11 testbenches**, one AXI memory BFM, and
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
| Common logic | [`async_fifo.sv`](../rtl/common/async_fifo.sv), [`sync_fifo.sv`](../rtl/common/sync_fifo.sv), [`rr_arbiter.sv`](../rtl/common/rr_arbiter.sv) | Gray-pointer CDC FIFO, synchronous FIFO, and round-robin arbitration. Present; async FIFO has its own test, others are exercised through subsystem tests. |
| MAC table configuration | [`mac_table_pkg.sv`](../rtl/mac_table/mac_table_pkg.sv) | Four 512-row banks, 48-bit MAC keys, eight-bit destination masks, nine-bit age, and eight learning/lookup request ports. |
| MAC table integration | [`mac_addr_table_top.sv`](../rtl/mac_table/mac_addr_table_top.sv), [`mac_table_bank.sv`](../rtl/mac_table/mac_table_bank.sv), [`bank_arbiter.sv`](../rtl/mac_table/bank_arbiter.sv) | Four-way table, bank arbitration, request FIFOs and response routing. Present; not connected to packet ingress. |
| MAC learning and aging | [`mac_learn_port.sv`](../rtl/mac_table/mac_learn_port.sv), [`learn_engine_fsm.sv`](../rtl/mac_table/learn_engine_fsm.sv), [`aging_sweep_fsm.sv`](../rtl/mac_table/aging_sweep_fsm.sv) | Learns or refreshes a source-port mask, selects replacement entries, and ages entries using an external tick. Tick generation and software configuration remain external. |
| MAC lookup | [`mac_lookup_port.sv`](../rtl/mac_table/mac_lookup_port.sv), [`lookup_engine_fsm.sv`](../rtl/mac_table/lookup_engine_fsm.sv) | Queues lookup requests and returns hit/mask results using a pipelined bank read path. Present; header extraction and miss policy are absent. |
| Shared buffer control | [`buf_mgr_pkg.sv`](../rtl/buf_mgr/buf_mgr_pkg.sv), [`buf_mgr_core.sv`](../rtl/buf_mgr/buf_mgr_core.sv), [`free_list_mgr.sv`](../rtl/buf_mgr/free_list_mgr.sv), [`queue_mgr.sv`](../rtl/buf_mgr/queue_mgr.sv) | Six-port alloc/enqueue/dequeue/release protocol, free-ID pool, reference counts, lengths, and per-port linked lists. Supports multiple destination bits for one buffer. Present and unit-tested. |
| DMA configuration | [`axi_dma_pkg.sv`](../rtl/dma/axi_dma_pkg.sv) | Five physical ports, 128-bit AXI data, 32-bit addresses, one-bit ID, and pool base `0x10000000`. |
| Physical ingress | [`ingress_top.sv`](../rtl/dma/ingress_top.sv), [`ingress_port_wr.sv`](../rtl/dma/ingress_port_wr.sv), [`ingress_dma_wr.sv`](../rtl/dma/ingress_dma_wr.sv) | Five stream receivers, local frame RAMs, shared DDR write engine, and an instantiated `buf_mgr_core`. Forwarding masks are external inputs. Present and subsystem-tested. |
| Physical egress | [`egress_top.sv`](../rtl/dma/egress_top.sv), [`egress_port_rd.sv`](../rtl/dma/egress_port_rd.sv), [`egress_dma_rd.sv`](../rtl/dma/egress_dma_rd.sv) | Five queue consumers, shared DDR read engine, local frame RAMs, and AXI-S transmit outputs. Buffer-manager and CPU handshakes are exposed for integration. Present and subsystem-tested. |
| PS GEM port | [`ps_gem_axis_bridge.sv`](../rtl/ps_eth/ps_gem_axis_bridge.sv), [`gem_rx_w_to_axis.sv`](../rtl/ps_eth/gem_rx_w_to_axis.sv), [`axis_to_gem_tx_r.sv`](../rtl/ps_eth/axis_to_gem_tx_r.sv) | One reusable full-duplex GEM FIFO/AXI-S bridge, intended to be instantiated twice. Width conversion and CDC exist; flush, overflow recovery, throughput, and real GEM timing need further work. |
| PL MAC port | [`pl_gmii_mac_top.sv`](../rtl/pl_gmii/pl_gmii_mac_top.sv), [`open_eth_mac_1g_switch.sv`](../rtl/pl_gmii/open_eth_mac_1g_switch.sv) | 1G full-duplex GMII MAC, switch-oriented receive acceptance, AXI-Lite register access, and wrapper. Intended to be instantiated twice. RGMII board interface is absent. |
| PL MAC stream adaptation | [`mac_rxd_to_switch_ingress.sv`](../rtl/pl_gmii/mac_rxd_to_switch_ingress.sv), [`switch_egress_to_mac_txd.sv`](../rtl/pl_gmii/switch_egress_to_mac_txd.sv) | Converts 32-bit MAC data/control streams to/from the 16-bit switch streams across clock domains. Reused by the SFP port. Present and adapter-tested. |
| SFP PCS | [`sfp_pcs_pkg.sv`](../rtl/sfp_pcs/sfp_pcs_pkg.sv), [`sfp_1000base_x_pcs.sv`](../rtl/sfp_pcs/sfp_1000base_x_pcs.sv), [`gmii_1000base_x_tx.sv`](../rtl/sfp_pcs/gmii_1000base_x_tx.sv), [`gmii_1000base_x_rx.sv`](../rtl/sfp_pcs/gmii_1000base_x_rx.sv), [`sync_1000base_x.sv`](../rtl/sfp_pcs/sync_1000base_x.sv) | GMII/1000BASE-X symbol conversion and code-group synchronization at a decoded GTH interface. Present and digitally tested. No serial transceiver or Clause 37 negotiation. |
| SFP port assembly | [`sfp_port_top.sv`](../rtl/sfp_pcs/sfp_port_top.sv) | Instantiates the PCS, imported 1G MAC, and stream adapters. Digital loopback test passes. It is a 1G design and stops at the GTH parallel boundary. |
| CPU port | [`cpu_port_top.sv`](../rtl/cpu_port/cpu_port_top.sv), [`cpu_dma_wr.sv`](../rtl/cpu_port/cpu_dma_wr.sv), [`cpu_dma_rd.sv`](../rtl/cpu_port/cpu_dma_rd.sv) | Reuses ingress/egress front ends at port 5 and supplies dedicated switch-pool DMA engines. Stream endpoints are ready for a separate CPU-facing AXI DMA IP. Present and subsystem-tested; that IP and its software are absent. |

The current buffer defaults reserve 256 slots of 2048 bytes, or **512 KiB of
DDR payload storage**, starting at `0x10000000`. Metadata and local frame/FIFO
storage are additional. This address is an RTL constant, not an established
FreeRTOS memory reservation. Raising buffer counts or frame size requires
review of RAM use, burst limits, alignment, and tests.

## Modules and integration still pending

The names below describe required functions, not files that already exist.

| Pending component | Required work / integration boundary |
| --- | --- |
| Ethernet header parser and forwarding engine | Extract source/destination MACs from each physical and CPU ingress stream. Respect the MAC table's busy/result handshakes, associate each result with its frame, and supply stable `dest_mask_i` / `dest_mask_valid_i` until enqueue completes. |
| Forwarding policy | Define unknown-unicast and broadcast/multicast flooding, ingress-port exclusion, CPU-directed traffic, and any mirror/filter rules. The queue manager can replicate buffer references, but it does not decide the destination mask. VLAN-aware forwarding is not implemented; the present table key is only a MAC address. |
| Whole-switch top level | Instantiate two GEM bridges, two PL MAC ports, one SFP port, ingress/egress tops, MAC table, and CPU port. Join all queue handshakes and adapt the eight-bit MAC-table masks to six switch ports. |
| PS/DDR AXI integration | Connect physical and CPU read/write masters through a suitable interconnect to PS DDR; define HP/HPC interfaces, reset domains, arbitration, and a reserved memory map. |
| CPU-facing AXI DMA SG | Instantiate/configure vendor DMA for 16-bit packet streams, descriptor access, software-owned data buffers, and interrupts. This is separate from the existing `cpu_dma_*` switch-pool engines. |
| FreeRTOS firmware | Implement GEM FIFO-mode and PHY initialization, DMA rings, cache maintenance, interrupt handling, network-stack input/output, and buffer ownership. No software directory or application build exists. |
| Management and status plane | Wire MAC AXI-Lite interfaces; provide forwarding configuration, aging tick/default-age controls, link status, drop/error counters, and CPU register/interrupt access. |
| PL RGMII board interface | Adapt GMII wrappers to carrier PHY RGMII signals, including RX clock handling, DDR I/O, delays, PHY reset, MDIO, and constraints. Existing MAC RTL targets 1G full duplex; 10/100 operation is not implemented by this wrapper. |
| SFP GTH integration | Generate a target-correct transceiver wrapper, reference clocks, startup/reset sequence, comma alignment, 8b/10b configuration, RX clock correction/CDC, and module control/status wiring. |
| SFP link management | Add Clause 37 negotiation or explicitly configure and validate a fixed 1000BASE-X peer. PCS synchronization alone is not link negotiation. |
| Board build and constraints | Add Vivado project/block-design Tcl, target-part/board settings, XPM support for the MAC's synthesis path, pin assignments, clocks, timing/CDC constraints, reset sequencing, and bitstream build. |
| Full-system verification | Exercise actual learning-driven forwarding through ingress, DDR, egress and all port types; add contention, flood, exhaustion, reset/error recovery and sustained-load tests, then synthesis/timing and board bring-up. |

A 10G SFP path would be a separate extension: the current 1000BASE-X PCS, 1G
MAC, stream widths/rates, buffering, and memory bandwidth would all need review.

## Known gaps in existing RTL

These findings are recorded for the initial check-in; the inventory does not
change the RTL or claim to resolve them.

| Finding | Evidence and remaining work |
| --- | --- |
| GEM RX flush does not discard all in-flight data | `gem_rx_w_to_axis` explicitly documents that flush suppresses later bytes but does not purge bytes already crossing the FIFO or held by the packer. Add a cross-domain abort/flush protocol and verify recovery into the next frame. The current flush test checks suppression, not recovery. |
| GEM FIFO throughput is below the stated 1G goal at the proposed fabric clock | `axis_to_gem_tx_r` pushes one byte per fabric cycle, taking two cycles for a full 16-bit word. At 62.5 MHz this caps its FIFO fill bandwidth at 500 Mb/s before other stalls. RX also drains a byte-wide FIFO in the fabric domain. Rework widths/clocking and test uninterrupted 1G traffic; the existing short-frame tests do not establish line rate. |
| GEM TX start and error recovery are incomplete | `tx_r_data_rdy_o` asserts whenever the FIFO is nonempty, rather than when a complete frame or sufficient guaranteed data is available. Underflow/error/flushed outputs are tied low, and status is acknowledged without recovery. Add a safe start policy and recovery sequencing. |
| Real GEM clock/interface assumptions need validation | The wrapper exposes a single `gem_clk` for RX and TX and an eight-bit RX data port. Confirm actual generated PS ports, byte validity, and RX/TX clocks against the target configuration. `rx_w_status_o` remains in the GEM domain and is not aligned with the fabric `TLAST`. |
| Frame-size and stream-contract enforcement | `ingress_port_wr` assumes frames fit the 2048-byte slot and accepts only its documented keep patterns; no explicit overlength drain/drop path is present. Its error decision samples `TUSER` on the final transfer. Define malformed-stream handling and enforce limits at every ingress, including CPU. |
| AXI error responses are ignored | Physical and CPU DMA engines explicitly do not check `BRESP` / `RRESP`. Add error propagation and recovery that preserves queue/refcount ownership. |
| Sustained traffic and slow destinations are unproven | Front ends hold one frame at a time; physical DMA engines serialize frame transfers. The shared pool has no completed per-egress admission/quota policy. Measure throughput and add buffering/drop policies so congested outputs or CPU capture cannot exhaust the pool indefinitely. |
| Existing lint warnings | `lint-pl-gmii` and `lint-sfp-port` fail with 31 and 36 warnings respectively under Verilator 5.020. Width expansion/truncation in the imported MAC, mixed timescales, and the `interrupt` symbol require review. |
| Synthesis and CDC are unverified | Portable simulation exercises a behavioral MAC TX memory path, while synthesis selects `xpm_memory_sdpram`. No synthesis, RAM-inference, physical CDC/reset, timing, or hardware evidence is included. |
| Test failures do not reliably fail the process | Existing benches print failures and call `$finish`. CI needs explicit fatal exits or a runner that checks failure and final-pass markers. |

## Historical comments to reconcile

- `ingress_top` / `egress_top` call the CPU interface a future module, but
  `cpu_port_top` now exists and should be connected to their passthrough ports.
- `buf_mgr_core` describes an older CPU path that skips DMA; the actual
  `cpu_port_top` uses two dedicated DMA engines.
- `axi_dma_pkg` and `cpu_port_top` describe Linux buffers. The intended OS for
  this project is FreeRTOS, and its software integration remains to be written.
- Several headers describe Icarus 12.0 workarounds. The checked-in baseline
  was freshly simulated with 13.0; no claim is made here about the root cause
  of those historical issues.

## Suggested development order

1. Implement header parsing, MAC learning/lookup integration, and destination
   policy; join the existing ingress/egress/CPU subsystems under one simulated top.
2. Resolve GEM streaming/abort behavior, frame limits, and DMA error handling;
   add sustained-traffic and recovery tests.
3. Add PS/DDR and CPU DMA integration, management registers, and FreeRTOS software.
4. Add the physical RGMII/GTH interfaces, clock/reset constraints, synthesis,
   timing closure, and hardware tests.
