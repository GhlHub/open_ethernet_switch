# Overall architecture

Inventory baseline: 2026-09-17. This describes the RTL present in this repository
and the integration still needed to make it a working KR260 switch.

**The implemented architecture is a store-and-forward switch using a shared PS
DDR packet pool.** PS GEM traffic enters PL through the GEM external FIFO
interface, bypassing the GEM's built-in DMA. The switch's own PL DMA engines
then store packets in DDR. These are different DMA paths.

## System view

Blue boxes have RTL in the repository. Amber boxes also have RTL but have
known functional or hardware-integration gaps. Red boxes marked **PENDING**
have no complete implementation here. Gray boxes are interfaces or existing
hardware resources. Arrows show the intended system connections; there is
**no system-level RTL wrapper or Vivado block design wiring this complete
diagram together yet**. Dotted arrows carry forwarding/control information.

```mermaid
flowchart TB
    subgraph ports[Physical port subsystems]
        PS["Ports 0-1: PS GEM adapters<br/>ps_gem_axis_bridge x2<br/>RTL present; flush / underrun gaps"]
        PL["Ports 2-3: PL 1G MACs<br/>pl_gmii_mac_top x2<br/>RTL present; RGMII wiring pending"]
        SFP["Port 4: SFP 1G MAC + PCS<br/>sfp_port_top<br/>RTL present; GTH / negotiation pending"]
        STREAM["Five physical RX / TX stream pairs<br/>16-bit AXI-S; intended 62.5 MHz"]
        PS <--> STREAM
        PL <--> STREAM
        SFP <--> STREAM
    end

    subgraph core[Switch datapath and buffer control]
        subgraph ingwrap[ingress_top - RTL present]
            INGRESS["Five ingress_port_wr instances<br/>Local frame RAMs + ingress_dma_wr"]
            BUF["buf_mgr_core<br/>free_list_mgr + queue_mgr<br/>Six queues; reference-counted buffer IDs"]
        end
        EGRESS["egress_top<br/>egress_dma_rd + five egress_port_rd<br/>Local frame RAMs"]
        CPU["Port 5: cpu_port_top<br/>Ingress / egress front ends<br/>Dedicated cpu_dma_wr / cpu_dma_rd"]
        PARSER["PENDING: per-port header parsing<br/>Learning / lookup requests<br/>Forwarding, flood and CPU-punt policy"]
        TABLE["mac_addr_table_top<br/>Learning + lookup + aging<br/>RTL present; not connected to packet path"]
        INGRESS <--> BUF
        EGRESS <--> BUF
        CPU <--> BUF
        PARSER -.-> TABLE
        TABLE -. lookup result .-> PARSER
        PARSER -. destination masks .-> INGRESS
        PARSER -. destination mask .-> CPU
    end

    STREAM --> INGRESS
    EGRESS --> STREAM
    STREAM -. received headers .-> PARSER
    CPU -. CPU transmit headers .-> PARSER

    subgraph platform[PS memory and software integration]
        AXI["PENDING: AXI interconnect + PS HP/HPC wiring<br/>Address map and arbitration"]
        DDR["PS DDR shared packet pool<br/>Default: 256 x 2048-byte slots<br/>Base address 0x10000000"]
        CPUDMA["PENDING: CPU-facing AXI DMA SG IP<br/>MM2S / S2MM and descriptor rings"]
        RTOS["PENDING: FreeRTOS firmware<br/>Drivers, network interface, PHY / GEM setup<br/>Register and interrupt control"]
        AXI <--> DDR
        CPUDMA <--> AXI
        RTOS -. buffer / descriptor management .-> CPUDMA
    end

    INGRESS -->|128-bit AXI writes| AXI
    AXI -->|128-bit AXI reads| EGRESS
    CPU <-->|128-bit AXI read / write| AXI
    CPU <-->|16-bit AXI-S| CPUDMA

    classDef present fill:#e1efff,stroke:#245a9b,color:#10243a
    classDef partial fill:#fff0cb,stroke:#a96a00,color:#473000
    classDef pending fill:#ffe4e4,stroke:#b52a2a,color:#601515,stroke-dasharray:5 3
    classDef hardware fill:#eeeeee,stroke:#666666,color:#222222
    class INGRESS,BUF,EGRESS,CPU,TABLE present
    class PS,PL,SFP partial
    class PARSER,AXI,CPUDMA,RTOS pending
    class STREAM,DDR hardware
```

Also pending across the whole diagram: board top level, clock generation,
reset sequencing, pin/timing/CDC constraints, management-register access, and
an end-to-end switch testbench.

## Physical-port boundaries

This diagram separates existing digital adapters from the missing board-level
pieces. Each double arrow represents receive and transmit paths.

```mermaid
flowchart LR
    PSHW["KR260 PS PHYs + hard GEM0 / GEM1"] <-->|External FIFO| GEM["RTL: ps_gem_axis_bridge<br/>gem_rx_w_to_axis<br/>axis_to_gem_tx_r"]
    GEM <--> AXIS["Common 16-bit AXI-S<br/>switch RX / TX interfaces"]

    PLPHY["KR260 PL copper PHYs"] <--> RGMII["PENDING: RGMII I/O<br/>Clocking, delay constraints, MDIO"]
    RGMII <-->|GMII| PLMAC["RTL: pl_gmii_mac_top<br/>open_eth_mac_1g_switch<br/>32-bit / 16-bit CDC adapters"]
    PLMAC <--> AXIS

    OPT["SFP module / serial link"] <--> GT["PENDING: target GTH wrapper<br/>Reset, alignment, 8b/10b, RX clock handling"]
    GT <-->|Decoded data + K flags| PCS["RTL: sfp_port_top<br/>1000BASE-X PCS + 1G MAC<br/>32-bit / 16-bit CDC adapters"]
    PCS <--> AXIS
    AN["PENDING: Clause 37 negotiation<br/>or validated fixed-link policy"] -.-> PCS

    classDef present fill:#e1efff,stroke:#245a9b,color:#10243a
    classDef pending fill:#ffe4e4,stroke:#b52a2a,color:#601515,stroke-dasharray:5 3
    classDef hardware fill:#eeeeee,stroke:#666666,color:#222222
    class GEM,PLMAC,PCS present
    class RGMII,GT,AN pending
    class PSHW,PLPHY,OPT,AXIS hardware
```

The SFP PCS operates at a decoded 8-bit, 125 MHz boundary. It does not contain
the serial transceiver or implement a 10G Ethernet path. Its `sync_ok_o` means
code-group synchronization, not a negotiated or hardware-validated link.

## Packet lifetime

1. A port adapter supplies a frame to `ingress_port_wr` over 16-bit AXI-S.
   The frame is collected in local RAM. An error on the final transfer drops
   it before allocation. Only one frame is in flight per front end.
2. The front end allocates a buffer ID from `buf_mgr_core`. The appropriate
   write DMA copies the frame into `DDR_BASE_ADDR + bufid * BUFFER_BYTES`.
3. A forwarding decision must provide `dest_mask_i` and
   `dest_mask_valid_i`. This producer is still missing; the testbenches supply
   masks directly. The ingress front end waits for the decision before enqueue.
4. `queue_mgr` records the length and links the buffer ID into each selected
   destination queue. `free_list_mgr` tracks the number of destinations. A
   zero mask frees the allocation without forwarding.
5. Each egress front end dequeues a buffer ID and uses its read DMA to copy
   the frame into local RAM. It releases its reference to the DDR slot once
   that copy completes, then streams the local copy to its MAC or CPU endpoint.
6. The shared DDR allocation returns to the free list after the final
   destination releases it. Multicast therefore shares one stored payload,
   with a separate read and local copy for each destination.

The CPU port uses the same front ends and buffer manager, but dedicated
`cpu_dma_wr` / `cpu_dma_rd` engines. A separate, not-yet-instantiated AXI DMA
SG block would move data between FreeRTOS-owned buffers and this port's streams.
The current CPU design therefore copies between software buffers and the
switch pool; it is not a direct zero-copy software interface to pool buffers.

## Current interface contract

| Interface | Current RTL contract |
| --- | --- |
| Switch packet streams | 16-bit `TDATA`, two-bit `TKEEP`, `TVALID`, `TREADY`, `TLAST`; low byte first |
| Partial final word | `TKEEP=01`; otherwise `TKEEP=11`. Sparse/empty keep patterns are not supported by the front ends. |
| Ingress error | `TUSER` sampled on the accepted final transfer; PL MAC adapters currently tie it low because the MAC filters bad frames. |
| Frame content | Ethernet header and payload; FCS excluded from switch streams. PS GEM receive configuration must match this convention. |
| Physical DDR access | One shared 128-bit write engine and one shared 128-bit read engine, each arbitrating five ports and allowing one outstanding frame burst |
| CPU switch-pool access | Dedicated 128-bit write/read engines; same pool geometry as physical ports |
| Port mask | Six bits in the buffer manager; eight bits in MAC-table results. Integration must define the mapping and disable unused table ports. |

Clock values in source comments are intended operating points, not timing-closure
results. In particular, the current GEM adapters transfer individual bytes on
their fabric-side FIFO ports, so a 16-bit external interface alone does not
establish 1 Gb/s sustained throughput. See the [inventory gaps](inventory.md#known-gaps-in-existing-rtl).
