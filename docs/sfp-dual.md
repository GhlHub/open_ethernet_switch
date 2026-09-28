# Runtime 1G / 10G SFP port

`KR260_SFP_MODE=dual` selects `ghlhub.org:ethernet:sfp_dual_port:1.0`.
Both 1000BASE-X and 10GBASE-R MAC/PCS paths are present in the same FPGA
image. The switch-facing stream remains 128 bits in either mode. The existing
`1g` (default) and `10g` builds retain their fixed-rate behavior.

```sh
python3 scripts/verify_ip_flow.py --sfp-mode dual --implement \
  --vivado /tools/Xilinx/2026.1/Vivado/bin/vivado \
  --output build/ip_refactor/sfpdual_acceptance
make -C software/r5 STATS_DDR=1 STATS_DEBUG=1
```

The configuration page exposes Auto, 1G and 10G for a dual-capable image.
Saving a forced rate causes the link task to remove SFP forwarding, wait for
queue flush completion and the existing 250 ms settling interval, then request
the new rate. Other ports retain their configuration. Auto starts at 10G and
tries the other rate after four seconds without a link, provided the module is
present and the port is enabled. It retains a working rate. This is host-protocol
probing, not copper autonegotiation or EEPROM-based module identification.
1G still uses the existing Clause 37 negotiation implementation; the wrapper
admits a link only with negotiated full duplex and no remote fault.

## Hardware and reset sequence

One GTHE4 channel at X0Y6 serves both paths. The fixed 156.25 MHz reference feeds
QPLL0 (10.3125 Gb/s host signaling) and QPLL1 (10 GHz VCO divided for 1.25 Gb/s
host signaling). The channel switches PLL selection, clock divider controls,
8b/10b/comma controls and 49 attributes across 37 DRP registers. QPLL1 avoids
adding a dynamically calibrated CPLL path.

`drp_fields.json` records every channel-attribute difference between generated
Vivado 2026.1 K26 profiles and the corresponding UG576 Appendix C bitfields.
The controller reads each register, preserves unrelated bits, writes its masked
value, then verifies the readback. It waits for GT power-good before DRP access.
Digital datapaths and user clocks are held in reset while clock mux/divider
controls change. Deasserting the Wizard reset-all request starts its reset
sequence after programming. Both TX and RX done flags must first be observed
low, preventing stale completion from the preceding mode from releasing the port.
The controller waits for both PLL locks and fresh TX/RX reset completion
before advertising ready. DRP timeout, readback mismatch and
lock timeout hold the port disabled; a new command retries the sequence.

TX user clocks are 156.25 MHz at 10G and 62.5 MHz at 1G. The 10G receive path
uses recovered RX clocks. The 1G elastic buffer uses the local TX user clock,
with the existing MMCM supplying the phase-related 125/62.5 MHz PCS clocks.
The mode-specific timing constraints describe both legal operating modes as
physically exclusive. The sideband controller holds TX_DISABLE while the GT
is not ready.

Vivado's static primitive model cannot infer the DRP-dependent output rate or
BUFG_GT division. The constraints specify both legal GT clock rates and both
divider settings, and prevent the inactive 10G clock from propagating through
the reset-held 1G MMCM. Static methodology reports retain TIMING-1 warnings
for the dynamic BUFG_GT dividers and TIMING-3 warnings for the explicit GT
output clocks. These are visible review items, not suppressed warnings. The
GTHE4 simulation checks the modeled frequencies; routed checks also verify
the exact clocks reaching each user-clock output and the 1G MMCM outputs.
Related clock trees carry `CLOCK_DELAY_GROUP` constraints, including the RX
mux outputs, and the RX muxes are placed at BUFGCTRL_X0Y8/X0Y9 beside the
transceiver to meet its RXUSRCLK/RXUSRCLK2 skew limit. The dual build
programs PL0's five receive-data IDELAYE3 cells to 900 ps in its implementation
hook; fixed-rate builds retain their existing settings. External RGMII timing
remains provisional without the carrier trace-delay data.

The CDC review retains explicit mode-control findings: protocol muxes and GT
mode pins change only while the paths are held reset, and the request/ready
handshake delays restart. Reset qualification has combinational assertions
followed by destination-clock release synchronizers. Ready/link/fault have
separate synchronizers for diagnostics and sideband control; software must
allow status to settle rather than treat those copies as an atomic snapshot.
These findings remain visible alongside the existing FIFO/mailbox and board
CDC findings; this is not a blanket CDC sign-off.

The digital port stops admitting new frames before requesting a mode change.
A discard decision lasts through TLAST. RX has a registered output that preserves
stalled beats; unexpected PHY loss terminates a partial frame with an error-marked
TLAST after any outstanding beat. Packets still buffered inside a MAC at a mode
change can be dropped. Switching is not lossless.

## Register interface

Base address: `0x800c0000`, AXI4-Lite management clock remains running throughout
mode changes. AW and W are captured independently; stalled responses are retained.

| Offset | Meaning |
|---|---|
| `0x404` | RX fabric admission, bit 28 |
| `0x408` | TX fabric admission, bit 28 |
| `0x4e0` | Requested mode: bit 0 = 0 for 1G, 1 for 10G; low-byte write requests reinitialization; requests while busy may coalesce |
| `0x4e4` | Status: bit 0 active GT mode, bit 1 GT ready, bit 2 error, bit 3 digital running, bit 4 link, bit 5 remote fault |
| `0x4ec` | Capabilities: bit 0 1G, bit 1 10G; value 3 |
| `0x4f0` | Active host rate, 1000 or 10000; meaningful with ready/running status |
| `0x4f4` | Same status as `0x4e4` |
| `0x4f8` | Core ID `0x4455414c` (`DUAL`) |
| `0x4fc` | ABI version 1 |

Only supported offsets above are implemented; other reads return zero and writes
are ignored. The eight statistics slots count fabric RX delivery and TX MAC
handoff, excluding FCS. They persist across mode changes. They are not wire
completion counters; internal MAC drops are not included in the wrapper counters.

## Verification and qualification

The digital tests exercise 10G → 1G → 10G loopback, frame tails through 1514 bytes,
backpressure, split AXI writes, capability registers and same-mode retry. Separate
controller tests cover reserved-bit preservation, DRP timeout, failed readback,
PLL timeout, stale reset-completion flags and recovery. The digital integration
test also verifies recovery of a GT that never became ready, and digital reset
when the GT is already ready. Stream-gate tests cover stalled output during PHY loss,
whole-frame discard across restart and frame-boundary quiescence. Firmware tests
check forced rates, flush ordering, stable-link Auto behavior and absent-module
hold. Browser tests check both rates and Auto in the dual build.

The Wizard profile audit can be regenerated independently:

```sh
/tools/Xilinx/2026.1/Vivado/bin/vivado -mode batch \
  -source scripts/check_sfp_dual_profiles.tcl \
  -tclargs build/sfp_dual_profiles_check
```

The actual Vivado GTHE4 model also exercises serial loopback in both modes,
including clock frequencies, 1G 8b/10b decoding and 10G header/data integrity.
The dual-mode acceptance driver includes the profile audit and GT model test.
The final routed image has +0.018 ns setup, +0.010 ns hold, and no pulse-width
violations under the current constraints. The minimum reported pulse-width
slack is 0.000 ns; the 10G RX user-clock skew margin is +0.329 ns.
Verification artifacts are under `build/ip_refactor/sfpdual_release3/`:
`final_results.json`, `reports_final/`, and
`project/kr260_switch.runs/impl_dual_timing2/kr260_top.bit`.
The complete 38 native/38 packaged tests and four statistics configurations
passed in `sfpdual_final`; the release run checks unchanged sources against
that baseline and reruns all three dual-core tests both natively and packaged,
the full profile audit, and the GT model simulation. Firmware host tests,
ELF verification and browser tests also pass; their logs are under
`build/sfp_dual_reference/`.

The image was subsequently loaded through volatile JTAG with an OEM SFP-GE-T
1G copper module. Auto reached 1G full duplex with GT status `0x1a`, PCS status
`0x7`, and LOS cleared after its cable was connected. A device subsequently
connected through the unmanaged switch was identified as `10.0.1.135`, with
its MAC learned on SFP (mask `0x10`). Concurrent short/full-MTU tests returned
1000/1000 and 999/1000 replies respectively. After deliberately selecting 10G,
Auto recovered 1G and a repeat full-MTU test returned 1000/1000 replies.
Both SFP packet counters advanced; see the dated hardware entry in
[verification.md](verification.md). The isolated initial loss is unexplained;
these results establish basic forwarding and recovery, not lossless line rate.
The user then hot-swapped to an XZSNET module identifying as `XZS-SFP10G-T`,
revision A. Auto acquired a 10G host link and forwarded traffic to the same
device through the user's 2.5G-capable switch. Tests showed 0.1–0.3% ping loss;
copper-only controls also showed 0.1% loss. This verifies basic hot swap and
10G host operation, not the actual negotiated copper rate or sustained
rate-conversion throughput. Evidence is in
`build/sfp_dual_reference/hardware_10g/` and the verification log.
Test insertion/removal, repeated switching, independent
link partners, RX elastic-buffer clock correction, reset recovery and traffic
under contention on hardware before relying on automatic operation.

This does not add SGMII host support, 2.5G/5G host modes, PAUSE/PFC, or guaranteed
10G throughput. The purchased copper module's exact host interface and power
consumption still require qualification against the cage power budget. See
[sfp-10g.md](sfp-10g.md) for the existing limitations.

References: [AMD XAPP1307](https://docs.amd.com/api/khub/documents/1hV9eUGGUngDBkSwkfZatw/content)
describes shared-transceiver runtime switching;
[AMD UG576](https://docs.amd.com/api/khub/documents/X8hVhAx~JVBkxiZRAjsdRg/content)
defines GTHE4 clocking, reset, and DRP fields. The implementation uses generated
K26 profiles, not the application note's board-specific register constants.
Clock-tree matching follows AMD's
[CLOCK_DELAY_GROUP guidance](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Using-the-CLOCK_DELAY_GROUP-Constraint-on-Several-Clock-Nets).
