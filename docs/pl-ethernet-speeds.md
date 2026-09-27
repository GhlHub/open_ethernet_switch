# PL copper full-duplex 10/100/1000 Mb/s

PL0 (left upper) and PL1 (left lower) implement independent 10/100/1000 Mb/s
full-duplex operation. The switch fabric and local MAC clocks remain 125 MHz.
GEM0 remains gigabit-only; SFP remains 1 Gb/s 1000BASE-X.

## Datapath

`pl_port` 1.1 enables independent receive/transmit byte strobes through
`EXTERNAL_PACING=1` in production. Existing native GMII simulation assemblies
use the default common clock enable. The MAC packet-RAM read enable follows
the transmit byte strobe, preserving its one-byte-ahead prefetch at low rates.
A disabled port discards queued TX descriptors and aborts an active frame
without counting it as successfully transmitted.

`rgmii_rate_adapter` in the physical shell drives the existing ODDRE1s:

| Link | Forwarded TX clock | Transfer | MAC byte enable |
| --- | --- | --- | --- |
| 1000 Mb/s | 125 MHz | Low/high nibble on rising/falling edges | Every clock |
| 100 Mb/s | 25 MHz | One nibble per clock, repeated on falling edge | Every 10 local clocks |
| 10 Mb/s | 2.5 MHz | One nibble per clock, repeated on falling edge | Every 100 local clocks |

TX clock generation uses the 125 MHz edge grid and finishes the current
nibble-clock pulse before stopping. No fabric/reference MMCM is reconfigured.
RX captures PHY-sourced edges, reconstructs bytes, and queues bytes plus an
explicit end-of-frame token in the asynchronous FIFO. A trailing partial
nibble marks that token erroneous; MAC admission and counters reject it
even if the preceding complete bytes have a valid CRC. Empty between received
bytes is normal; the MAC advances only on its independent receive strobe.
The legacy matched-rate elastic FIFO is no longer the production receive path.
Its underrun diagnostic is held zero; FIFO overflow remains a sticky error.

The mode bus uses two speed synchronization stages and four enable stages.
Firmware holds speed stable while disabled before enabling it. RX disable
asynchronously clears the enable chain even when RXC is stopped; that chain
provides synchronous reset release for receiver arming. TX enable is registered
in the control domain before synchronization. Reception arms
only after FIFO reset-busy clears and an idle symbol is observed. Speed changes
may drop in-flight frames; transitions are not lossless.

## Registers and firmware ownership

| Register | Meaning |
| --- | --- |
| PL MAC base + `0x41c` | Bits 1:0: 0=10, 1=100, 2=1000; bit 2: physical port enable. Reset is 2 (gigabit, disabled). Encoding 3 is rejected. |
| PL MDIO base + `0x18` | Bit 0 pauses new hardware PHY polls; an active poll completes normally. Reset is 0. |
| PL MDIO STATUS + `0x10` | Existing link/speed/duplex/valid fields; new bit 10 reports PHYSTS speed/duplex resolved. |

MAC bases are `0x80040000`/`0x80080000`; MDIO bases remain
`0x80010000`/`0x80020000`, with PHY addresses 2/3. `pl_phy_mdio` is version 1.1.
The R5 link task is the single owner of advertisement and port-mode changes.
It removes a changed port from forwarding, waits at least 250 ms and for
fabric flush completion, then configures the port. PHY setup pauses polls,
waits for the MDIO master to become idle, writes full-duplex advertisements
(registers 4/9), restarts autonegotiation, and resumes polling on both success
and error. The sequencer also yields to an active/starting CPU transaction.

Admission requires initialized, valid, resolved, full-duplex link status,
IDELAY calibration and a negotiated ability included in the applied mask.
Unsupported/half-duplex links stay outside forwarding. The next polling
interval after speed programming can re-enable the port. A forced-speed peer
without autonegotiation may resolve half duplex and is deliberately rejected.

The saved configuration already contains four copper advertisement masks;
no SD format change is needed. Web configuration applies all four masks and
SNMP port column 13 reports them. `GET /api/ports` returns four-element
`advertise`/`applied` arrays. The legacy PS-only POST remains accepted; a full
POST may include `adv0` through `adv3` together. Speed reporting covers all
physical ports. SNMP remains read-only and configuration writes require login.

## Timing and verification

I/O timing retains the tight 125 MHz RGMII envelope for all rates. Slow-mode
TX clocks/data use subsets of the same ODDRE1 launch edges, with no relaxed
multicycle data-path exceptions. PHY internal delays and per-port fixed RX
IDELAY values are unchanged. External board/PHY budget qualification remains
an existing open item, separate from functional speed support.

The focused suite exercises actual MACs plus the rate converter at each speed:
independent wire-byte/preamble/FCS checks, full-size and short back-to-back
frames, descriptor wrapping, counters and injected receive errors. Additional
independent RX clocks test ppm offset, stopped clocks, partial nibbles, mode
changes and full-width TX clock pulses. Firmware tests cover both ports,
advertisement subsets, flush ordering, half-duplex/unresolved rejection and
MDIO error recovery. Browser tests select PL capabilities and preserve settings.

See the dated [verification record](verification.md) for completed build and
board checks. Congestion from fast ingress to slow egress can legitimately
exhaust buffers and drop packets; broader simultaneous-port qualification
remains separate work.
