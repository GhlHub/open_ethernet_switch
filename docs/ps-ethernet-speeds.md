# PS Ethernet full-duplex speed selection

The R5 link service supports negotiated 10, 100 and 1000 Mb/s full-duplex
operation on GEM1 (right lower, RGMII). GEM0 (right upper, PS-GTR SGMII)
remains 1000 Mb/s only. AMD UG1087 network_config explicitly limits 10/100
to RGMII, despite the more general speed-adaptation wording in UG1085.
PL0, PL1 and SFP remain 1000 Mb/s only. Half-duplex links are never enabled
for forwarding, even if a PHY reports link up. The partner must negotiate a
common full-duplex ability; a forced-speed partner without auto-negotiation
can resolve as half duplex through parallel detection and will be rejected.

The configuration webpage provides independent 10/100/1000 full-duplex
advertisement checkboxes for GEM1. At least one must remain selected,
even on an administratively disabled port. GEM0 displays its fixed 1000FD
ability with disabled controls. Defaults are GEM0=1000FD and GEM1=all three.
Settings are volatile. Changing an advertisement restarts that PHY's copper
negotiation and interrupts traffic on that port. Administrative enable/disable
remains independent of advertised capabilities.

## Implementation

`port_policy.c` encodes PHY advertisements, decodes DP83867 PHYSTS and builds
GEM network/clock configuration. PHY register 4 advertises only selected
10FD/100FD abilities and the IEEE selector; register 9 advertises 1000FD
when selected. No half-duplex or pause capabilities are advertised. The link
service requires PHYSTS link, speed/duplex-resolved and full-duplex bits,
rejects reserved speed encodings, and checks the applied ability mask.

`links.c` owns MDIO and all clock/MAC changes. Web requests atomically publish
a requested administrative mask and two advertisement masks. At each 250 ms
poll, a changed configuration, changed speed or invalid PHY status removes
the affected port from desired forwarding and disables its GEM RX/TX. The
existing link policy clears its queues/MAC entries. The service waits at least
one polling interval and for flush-busy to clear before restarting negotiation
or changing the clock and MAC configuration. A later poll can enable forwarding.
Unchanged requests do not restart negotiation. The existing flush completion
and CDC assumptions still apply; this does not guarantee lossless transitions.

The generated PS preset uses integer IOPLL at 1 GHz. GEM1 reference-clock
divisors are /8 /1 at 1000, /8 /5 at 100, /8 /50 at 10, producing 125,
25 and 2.5 MHz. Initialization checks the expected preset selector/divisors.
GEM0 reference clock, PS-GTR reference and SGMII data rate remain unchanged
at their existing gigabit settings. No PL MAC,
packet format, DDR interface or switch-fabric clock changes are required.

Reference material: [AMD UG1085](https://docs.amd.com/r/en-US/ug1085-zynq-ultrascale-trm),
chapter 34 external FIFO interfaces;
[AMD UG1087 network_config restrictions](https://docs.amd.com/r/en-US/ug1087-zynq-ultrascale-registers/network_config-GEM-Register);
[AMD GEM speed control implementation](https://github.com/Xilinx/embeddedsw/blob/master/XilinxProcessorIPLib/drivers/emacps/src/xemacps_control.c);
[AMD GEM clock-divisor implementation](https://github.com/Xilinx/embeddedsw/blob/master/ThirdParty/sw_services/lwip220/src/lwip-2.2.0/contrib/ports/xilinx/netif/xemacpsif_physpeed.c);
[TI DP83867 datasheet](https://www.ti.com/lit/ds/symlink/dp83867cs.pdf), PHYSTS/ANAR/1KTCR.

## Management interfaces

`GET /api/ports` adds `advertise` and `applied` arrays for GEM0/GEM1, plus
six `speed_mbps` values. Capability mask bits are 1=10FD, 2=100FD, 4=1000FD.
A difference between requested/applied masks means the change is pending.
`POST /api/ports` accepts `mask=31&adv0=4&adv1=7`. Both ability fields must be
present together; adv0 must be 4 and adv1 must be 1..7; a legacy mask-only request preserves abilities.
Invalid, duplicate, missing or unknown fields are rejected before mutation.

`GET /api/statistics` adds the same six-element `speed_mbps` array. Both web
pages display speed; the statistics page continues its one-second refresh.
Physical speed can remain nonzero while administratively disabled. Zero means
no supported resolved link, or the CPU virtual port (which has no PHY speed).
The existing `physical` mask means a supported resolved full-duplex link.

SNMP port table columns 12 (`krPortSpeedMbps`, Gauge32, Mb/s) and 13
(`krPortAdvertise`, Gauge32 capability mask) report speed and requested PS
advertisement. Existing column 11 is the inaccessible index and is unchanged.
Non-PS advertisement rows return zero. Existing port-link objects continue to
report fabric link state. SNMP remains read-only. The supplied reader reports
both fields in JSON and link speeds in text.

Web sensor voltages and current have exactly three fractional digits
(`1.800 V`, `0.800 A`) and
PS/PL temperatures one (`30.0 °C`), including zero padding. Raw API/SNMP
sensor units and precision are unchanged.

## GEM0 hardware limitation

An experimental GEM0 100FD advertisement negotiated 100 Mb/s at the copper PHY
but failed endpoint pings. That endpoint was subsequently confirmed to be
gigabit-only, so this experiment cannot independently establish the GEM0
limitation. AMD UG1087 explicitly documents the restriction. Lower rates
are rejected for GEM0 in both the HTTP parser and configuration API,
and its startup advertisement remains 1000FD only. Supporting slower GEM0
traffic requires a different MAC-PHY hardware path or a rate-converting bridge;
changing PHY advertisement alone cannot provide it.

## Verification

`make -C software/r5 test` includes the real link service with modeled MDIO,
MAC and clock registers: subset advertisement, speed/clock changes, flush
waiting, unchanged settings, admin state, half-duplex/unresolved/reserved
rejection and invalid requests. SNMP tests cover new objects in all four
counter builds; HTTP tests cover capability validation and JSON output.
`make -C sim sim-ps-eth-multirate` runs the existing RX/TX/overflow/flush tests
at 125, 25 and 2.5 MHz with the fabric clock held at 100 MHz. These are
behavioral FIFO-interface checks, not a model of the PS-GTR or physical PHY.
`tests/test_web_browser.js` checks the UI with Playwright, including capability
posting/validation, speed text, polling, and padded sensor formatting.

Board validation with a managed-switch uplink on GEM1 passed 20/20 full-MTU
pings to the R5 and GEM0 endpoint at each of 10, 100 and 1000 Mb/s, plus
the all-speed advertisement setting. HTTP/SNMP reported matching speeds.
The endpoint itself supports only gigabit, so it was kept on GEM0 for these
tests. See [verification](verification.md) for evidence and limits.
