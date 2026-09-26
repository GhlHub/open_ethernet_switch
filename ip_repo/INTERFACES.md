# Digital IP interface contracts

These contracts describe the checked-in RTL and KR260 production integration.
They do not extend port speed support. Manifests select source files, public
module names and catalog versions; changing the public hardware interface
requires a new catalog version and regeneration of dependent block designs.
The processor ABI is versioned separately by the capability register.

## Common packet and reset rules

Every switch-facing packet interface is 16-bit AXI-Stream with two byte
enables. A transfer occurs only with TVALID and TREADY high. The producer
holds data, byte enables, TLAST and any TUSER stable while stalled. TLAST
marks the final word; odd-length frames use one valid byte there. Byte lane
zero carries the earlier byte. Frames exclude the Ethernet preamble and FCS
at this boundary. Receive interfaces with TUSER convey frame error status.
An AXI-Stream slave is an input to the IP, not necessarily network ingress:
a port's slave stream transmits toward its PHY; the fabric's slave streams
receive from those ports.

Reset signals are active low. Integrators must provide domain-appropriate
reset release and stable clocks. Coordinated reset discards in-flight
packets, buffer ownership, learned addresses and hardware counter intervals.
Link-down/flush controls are the normal operational mechanism for removing
a port; arbitrary independent reset of a live producer/consumer is not an
advertised lossless recovery mechanism. The MAC additionally reclocks its
reset release internally. Existing CDC reports still require review; these
contracts are not physical CDC sign-off.

## Package boundaries

| Catalog name | Version / public module | Clocks and reset inputs | Interfaces / ownership |
| --- | --- | --- | --- |
| `gem_port` | 1.0 / `switch_gem_port` | `clk/rst_n`; `gem_rx_clk/gem_rx_rst_n`; `gem_tx_clk/gem_tx_rst_n` | 16-bit packet streams, PS GEM external RX-write/TX-read FIFO signals, two local counter banks |
| `pl_port` | 1.0 / `pl_gmii_mac_top` | `clk/rst_n`; `axis_clk/axis_rst_n`; `gtx_clk`, `clk_en` | Packet streams; 32-bit AXI-Lite MAC registers; 8-bit GMII; local counter bank |
| `sfp_port` | 1.0 / `sfp_port_top` | `clk/rst_n`; `axis_clk/axis_rst_n`; `gtx_clk/gtx_rst_n`; `gth_clk/gth_rst_n` | Packet streams; 32-bit AXI-Lite MAC registers; decoded 16-bit GTH data/control; PCS status; local counter bank |
| `switch_fabric` | 1.1 / `switch_fabric` | `clk/rst_n`; `axis_clk/axis_rst_n` | Five physical packet-stream pairs, CPU stream pair, three DDR AXI masters, shared packet buffers/queues, forwarding table, six counter banks |
| `management` | 1.2 / `switch_management` | `clk/rst_n` (production control clock) | 32-bit AXI-Lite controls, link/forward/learn masks, CPU TX ABI identifier and RX tag, statistics mailbox and 13-bank decoder |

In production, the fabric runs at 100 MHz, control at approximately
142.857 MHz, PL GMII at 125 MHz, and SFP PCS/GTH at 125/62.5 MHz. Packet
streams on all packages use `clk`; MAC AXI-Lite uses `axis_clk`.
The GEM FIFO clocks follow the negotiated link. The bridge is tested at
125/25/2.5 MHz, but KR260 GEM0 is restricted to 1 Gb/s by the current board
integration. GEM1 supports full-duplex 10/100/1000 Mb/s. PL copper and SFP
currently support only 1 Gb/s full duplex. Faster SFP settings stored in
configuration are not implemented hardware capabilities.

PL RGMII, receive elasticity, MDIO, PHY reset and clock generation remain
board-shell dependencies. SFP GTH, clock generation and module sideband
protection also remain board-shell dependencies. Their eventual packaging
must preserve delay groups, reference clocks, reset ordering and pin timing.

## Fabric controls and DDR

Port numbering is GEM0=0, GEM1=1, PL0=2, PL1=3, SFP=4, CPU=5.
Physical ingress is `s00_axis` through `s04_axis`; physical egress is
`m00_axis` through `m04_axis`. `cpu_s_axis` receives CPU-originated frames;
`cpu_m_axis` delivers CPU-destined frames.

`m_axi_ing` writes physical ingress packets; `m_axi_egr` reads packets for
physical egress; `m_axi_cpu` reads/writes CPU packet transfers. Data width is
128 bits and address width 32 bits. Integration must preserve AXI handshakes,
burst responses and the DDR address mapping. The production interconnect
ties omitted cache attributes to zero explicitly. CPU AXI DMA descriptors
are owned by the R5/PS DMA path, not these fabric masters. See
[the memory map](../docs/memory-map.md) for allocation and ownership.

`link_up_i`, `link_flush_tog_i`, `fwd_en_i` and `learn_en_i` are provided
in the control domain; the fabric owns their crossings. Link/forward/learn
disable triggers the existing drain/invalidation behavior. CPU TX carries
[per-frame metadata](../docs/cpu-tx-metadata.md) in a mandatory two-byte stream
header; it has no separate override CDC. CPU RX tags are consumed in the
control domain once per retired RX descriptor.

Parameters `STATS_DDR` and `STATS_DEBUG` each accept 0 or 1 and must match
management and firmware. `AGE_TICK_DIVIDE_COUNT` controls the fabric aging
tick (default 25,000,000 cycles); it is shortened only in simulation fixtures.
The SFP's three `AN_*_CYCLES` timers default to short simulation values;
production explicitly sets all three to 1,250,000. Integrators must not
use the simulation defaults for a board image.

## Statistics mailbox

Management owns the request selection and bank routing. `stats_select[3:0]`
is shared; each bank has a level request, level acknowledgment and stable
32-bit value. Bank implementations own the source-clock synchronization and
clear-on-capture. The handshake is request high, acknowledgment high,
request low, acknowledgment low. Software serializes destructive reads and
accumulates intervals in memory; web/SNMP clients read those totals.

| Global banks | Management pins | Owner |
| --- | --- | --- |
| 0–1 | `gem0_req/acks/values` | GEM0 RX/TX |
| 2–3 | `gem1_req/acks/values` | GEM1 RX/TX |
| 4 | `pl0_req/acks/values` | PL0 |
| 5 | `pl1_req/acks/values` | PL1 |
| 6 | `sfp_req/acks/values` | SFP |
| 7–12 | `fabric_req/acks/values` | CPU, DDR and debug counters |

Flattened value vectors store the lowest bank in the least-significant
32-bit word. Banks 13–15 acknowledge immediately with zero; unimplemented
slots and disabled counter groups return zero. `STATS_TIMEOUT` defaults to
4095 control cycles. Timeout returns `0xFFFFFFFF` without canceling the
request or permitting a new index. Retry the same read and complete release
before selecting another index. See [statistics](../docs/statistics.md).

## Production address ownership

| Base / aperture | Owner |
| --- | --- |
| `0x80000000` / 64 KiB | PS-to-fabric AXI DMA |
| `0x80010000`, `0x80020000` / 64 KiB each | Board PL0/PL1 MDIO |
| `0x80030000` / 64 KiB | Board SFP I2C |
| `0x80040000`, `0x80080000` / 256 KiB each | PL0/PL1 MAC |
| `0x800C0000` / 256 KiB | SFP MAC |
| `0x80100000` / 64 KiB | Management, including indirect statistics |

Management 1.2 retires the CPU override at 0x4C and adds CPU_TX_ABI at 0x54.
Statistics capability bits, bank numbers and interrupt routing are unchanged.
`check_production_bd.py` checks these production addresses and connections.
Do not infer the deployed address map from the separate validation BD's
automatic address assignment.
