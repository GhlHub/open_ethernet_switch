# SFP hardware investigation (2026-09-20)

The module fitted after the four-copper-port test is an Ipolex ASF-GE-T,
1000BASE-T RJ45 SFP. Its EEPROM at I2C address `0x50` identifies vendor `OEM`
and part `SFP-GE-T`. The PHY at `0x56` returns ID words `0x0141:0x0cc1`.
EEPROM and PHY reads through the PL AXI IIC at `0x80030000` work on hardware.
The identification transactions only select register offsets and read data;
no EEPROM contents were programmed. `software/r5/sfp_status_jtag.tcl` repeats
these reads without stopping R5; the current firmware leaves the IIC core
unused, so it is available exclusively to the diagnostic script.

[Ipolex's datasheet](https://m.media-amazon.com/images/I/91ze2PnD7DL.pdf)
lists ASF-GE-T as the 1000 Mb/s SERDES variant, distinct from the SGMII
multirate variants. Its TX_DISABLE resets the module, TX_FAULT is tied low,
and LOS can be tied low. Consequently, SFP_STATUS=0 proves presence and
that the host permits operation, but does not establish a working link.

## Initial evidence

The running copper-test image reports SFP_STATUS=0, PCS_STATUS=0 and
LINK_STATUS=0x20. Firmware leaves only CPU port 5 enabled because neither
PCS synchronization nor negotiation link is asserted. Both PL PHYs report
link down and the R5 timers continue advancing. This failure precedes DHCP. PHY status `0xbc00` indicates resolved 1 Gb/s
full duplex on the copper side. Register 27 is `0x8088`: mode 8 corresponds
to copper-to-1000BASE-X with negotiation, consistent with the
[Linux Marvell PHY driver definitions](https://github.com/torvalds/linux/blob/master/drivers/net/phy/marvell.c).

## Confirmed receive-status wiring defect

The GTH wrapper incorrectly used RXCTRL2 as RXCHARISK and RXCTRL0 as
RXDISPERR. According to [AMD UG576, RX 8B/10B decoder ports, Table 4-27](https://docs.amd.com/api/khub/documents/X8hVhAx~JVBkxiZRAjsdRg/content):

| GTH output | Meaning | Correct PCS destination |
| --- | --- | --- |
| RXCTRL0 | K/control-character indication | `rxcharisk_o` |
| RXCTRL1 | Disparity error | `rxdisperr_o` |
| RXCTRL2 | Comma indication | Unused by wrapper |
| RXCTRL3 | Invalid code | `rxnotintable_o` |

The old mapping falsely reports control characters as errors and fails to
identify non-comma K characters. `gth_sfp_wrapper.sv` now uses the documented
mapping. `make -C sim sim-gth-rx-mapping` tests all combinations of K,
disparity, comma and invalid flags on both byte lanes using the actual wrapper
and an interface stub. It fails on the old RTL and passes on the correction.
This is a wiring regression, not an analog transceiver model. Existing PCS
and SFP port simulations also pass; their previous behavioral models bypassed
the synthesis wrapper and therefore could not catch this defect.

A routed-checkpoint ECO changed only the two receive-status connections per
byte lane, then rerouted and produced `build/gem1_debug/sfp_mapping.bit`.
Setup/hold slack remains +0.018/+0.010 ns under existing constraints. The
corrected image was loaded through volatile JTAG; no flash was written.
PCS_STATUS remains zero, so this confirmed bug is not the only blocker.

## Additional instrumentation

`build/debug_sfp.tcl` builds two ILAs from a fully linked synthesis checkpoint
with implementation constraints and regenerated option-2 GTH IP. It also binds the two PCS receive-status
register inputs to the corrected GTH outputs, supporting the earlier local
checkpoint. Outputs are under ignored `build/gem1_debug/sfp/`.

- `ila_sfp_status`: 50 MHz always-running clock, 1024 samples. GTH power-good,
  CPLL lock/reference loss, TX/RX reset done, PMA reset done, byte alignment,
  comma detect, GT reset inputs, SFP MMCM lock and wrapper reset release.
  The fresh build additionally probes CPLL reset/power-down, TX/RX user-ready
  and TXOUTCLK selection.
  Negotiation state, transmitted ability/ACK and restart/link timers are also
  captured. Asynchronous status samples are diagnostic snapshots, not timing evidence.
- `ila_sfp_data`: GTH 62.5 MHz user clock, 2048 samples. RX data, K/disparity/
  invalid flags, RX buffer status, TX data/K flags and comma indications.

`build/capture_sfp.tcl` snapshots both cores on a running board. A stopped
GTH clock may prevent the data capture; the independent status core can
still identify reset/clock problems. The script restores the JTAG frequency
on completion or failure.


## Clock/reset capture

The SFP ILAs confirm GTH power-good and CPLL lock are asserted, but TX/RX
RESETDONE are zero, RX PMA reset is incomplete, GTRXRESET is high, the SFP
MMCM is unlocked and the wrapper remains in reset. Hardware Manager reports
the data ILA's GTH user clock stopped. The 50 MHz status capture contains
1024 consistent samples. This identifies a startup failure before symbol
reception, not evidence of a receive-buffer overflow.

The generated IP for `ENABLE_COMMON_USRCLK=1` selects RXOUTCLK for **both**
user-clock networks (`C_TX_USER_CLOCKING_SOURCE=2`, RX source 0). Both networks
also use the RX PMA reset-done qualifier. The reset controller waits for TX
startup before releasing RX, leaving TX without its required user clock.
The old wrapper comment incorrectly described option 1 as TX-derived.

Regenerating the IP with `ENABLE_COMMON_USRCLK=2` selects TXOUTCLK for both
networks (TX source 0, RX source 2), with TX PMA reset-done qualifying clock
release. The repository XCI source has been updated from the Wizard-generated
configuration. The first in-place clock ECO failed routing validation and was not loaded.
A subsequent fully routed topology experiment passed DRC and setup/hold
(+0.018/+0.011 ns), but its hardware capture still showed stopped clocks,
with both GT resets asserted. This experiment did not establish successful
startup. The debug flow now requires a freshly synthesized, regenerated
Wizard configuration rather than approximating its clock/reset/calibration
connections through checkpoint rewiring. A top-level re-synthesis initially
reused the old `gth_sfp_ip.dcp` even after `generate_target all`; netlist tracing
confirmed both user BUFGs still used RXOUTCLK. Explicitly reset and run
`gth_sfp_ip_synth_1` when changing this IP. The debug script now rejects an
input checkpoint with no user-clock load driven by TXOUTCLK. The original copper-test image is
preserved under ignored `build/gem1_debug/copper_passing/`.

The CPLL reference-loss probe reads high but its lock-detection reference-clock
input was not configured for that monitor; UG576 requires CPLLLOCKDETCLK for
valid reference-loss indication. Do not interpret this probe as proof that
the board oscillator is missing; CPLLLOCK is high.

## Startup verified; gearbox correction

After explicitly rebuilding the GTH synthesis run, the hardware capture shows
TX/RX reset done and PMA reset done high, TX/RX user-ready high, MMCM locked,
wrapper reset released, and RX byte alignment established. Both ILAs capture.
The image meets setup/hold at +0.018/+0.010 ns under the existing constraints.

The raw RX stream contains valid `/C1/` and `/C2/` words advertising `0x4020`
(full duplex, ACK set), without disparity or invalid-code errors. RX buffer
status is zero in this capture. Our transmitter still advertises `0x0020`;
PCS_STATUS is `1` (synchronized, negotiation incomplete), and 10 pings receive
no replies. This narrows the next blocker to the digital PCS rather than the
module's copper link or GTH startup.

The PCS test originally selected a favorable clock phase and explicitly
avoided coincident edges. At a coincident edge, the RX word register can
change between reading its low and high bytes, reversing/mixing the symbol
sequence presented to negotiation. The old RTL reproduces hardware's symptom:
sync succeeds, negotiation times out, and packet tests receive no data.

The corrected gearbox commits complete TX words and retains the corresponding
RX high byte when consuming a low byte. `sim-sfp-pcs-phases` checks negotiation,
packet contents, error propagation and resynchronization at four clock phases
(4, 8, 12 and 16 ns first GTH edges) and both receive byte alignments.
All eight cases pass; the old RTL fails the first phase. The SFP port, two-partner negotiation and switch tests also pass.
These remain related-clock transfers requiring setup/hold closure.

For the next hardware image, the board supplies 10 ms restart and 10 ms
acknowledgement/idle timers at 125 MHz through newly exposed SFP/switch
parameters. The prior source comment confused this with the 1.6 ms SGMII
link timer; [AMD PG047 describes the distinction](https://docs.amd.com/r/en-US/pg047-gig-eth-pcs-pma/Using-the-SGMII-MAC-Mode-to-Interface-to-an-External-BASE-T-PHY-with-SGMII-Interface).
Generic module defaults remain short for simulation. The regenerated
GTH configuration enables clock correction on `/I2/` (K28.5,D16.2) and the
`/C1/` prefix (K28.5,D21.5), with a full RX buffer and comma-alignment reset.
These sequences follow [AMD PG047](https://docs.amd.com/r/16.2-English/pg047-gig-eth-pcs-pma/Clock-Correction-Sequences-in-Device-Specific-Transceivers).
`sim-autoneg-clock-correction` verifies that fragments alone do not negotiate,
and intact configurations still complete negotiation amid inserted/deleted
prefixes. Sustained frequency-offset operation and buffer-error recovery
remain to be validated. The gearbox/timer/correction image established link
(PCS_STATUS=7, LINK_STATUS=0x30) after a module restart, but DHCP still failed.

## Receive preamble and negotiation restart corrections

With link established, the SFP MAC counted 381 received frames and 402 FCS
errors. A GTH capture contained a complete incoming frame with a valid FCS
(`0xe1222695`), but only five preamble bytes after `/S/`, followed by the SFD.
The old receiver assumed six bytes and synthesized an SFD: it consumed the
actual SFD as preamble and discarded the first destination-address byte.
[AMD PG047 documents this permitted preamble shrinkage](https://docs.amd.com/r/en-US/pg047-gig-eth-pcs-pma/Preamble-Shrinkage).

`gmii_1000base_x_rx.sv` now forwards the received preamble and transitions on
the actual SFD. `sim-sfp-rx-preamble` checks every byte and FCS of a synthetic
frame with both five and six post-`/S/` preamble bytes. The old RTL fails the
shortened case; the corrected RTL passes both.

Negotiation also accepted an all-zero restart configuration as an ability,
and advertised its normal ability during its own restart interval. The FSM
now transmits zero during restart, advertises its ability after the restart
timer, rejects zero as an ability and restarts if zero arrives while waiting
for acknowledgement. The clock-correction regression now checks this case:
the old RTL incorrectly acknowledges zero; the new RTL does not.

The PCS phase matrix, SFP port, two-peer negotiation and switch regressions
pass with both corrections. The image meets setup/hold at +0.016/+0.010 ns.
A fresh JTAG boot negotiates automatically without manually resetting the
module: PCS_STATUS=7, LINK_STATUS=0x30. The first MAC snapshot has 195 good
received frames and zero FCS errors. Incoming network frames also appear
correctly in R5 DMA buffers. DHCP still fails.

## Transmit ordered-set alignment

A subsequent GTH capture contains a 318-byte DHCP Discover (including FCS)
with valid CRC `0x52f19a99`. However, the TX state machine can start `/S/`
in the odd position, interrupting an idle ordered set, and always appends
one `/R/` regardless of the termination position. Its previous comments
incorrectly described these choices as harmless simplifications.

The transmitter now completes an idle pair before starting `/S/`, discarding
one preamble byte on an odd GMII start. It preserves even/odd parity through
the frame and emits one or two `/R/` symbols to restore an even-position
idle comma. See AMD PG047's [start encoding](https://docs.amd.com/r/en-US/pg047-gig-eth-pcs-pma/The-Odd-Transmission-Case?contentId=FMfrN19njQuZUaeW~MZ6Bw)
and [end encoding](https://docs.amd.com/r/en-US/pg047-gig-eth-pcs-pma/The-Odd-Transmission-Case).
`sim-sfp-tx-alignment` checks both GMII start phases and both frame-length
parities, including payload preservation. The old RTL fails the alignment
check; the correction passes. The PCS phase matrix accepts only the two
legal preamble lengths and still compares packet contents exactly. PCS,
SFP port, two-peer negotiation and switch regressions pass.

The alignment-only build was stopped before programming to incorporate
idle-disparity selection. Reading the module's fiber register bank twice
showed BMSR `0x0149`, partner advertisement `0x4020` and PHY status `0xa410`.
The page selector was restored to zero after each diagnostic read. These
were initially interpreted as incomplete serial-side negotiation, but the
same values persist while DHCP and ping work. Do not use these fiber-bank
bits as a link-admission criterion in this module's SFP converter mode.

The GTH word output now tracks 8b/10b running disparity across both AN and
frame symbols. It replaces an `/I2/` candidate with `/I1/` when the preceding
comma started at positive disparity, returning subsequent idles to negative
disparity. The test `sim-sfp-tx-idle` uses canonical subcode tables and bit
population counts as an independent oracle: all 256 data values, AN-like
words and both idle word alignments pass, exercising 244 `/I1/` and 268 `/I2/`
selections. The old output stage fails this test. Existing PCS/port/AN/switch
tests also pass.

## Hardware traffic result

The first combined image remained synchronized but exchanged zero restart
configurations; a module TX_DISABLE restart did not recover it. A subsequent
build adds state, advertisement and restart/link timer probes to the status
ILA. This image meets setup/hold at +0.018/+0.012 ns after the same 900 ps
PL0 IDELAY override used for the copper milestone. It boots, negotiates and
acquires DHCP address `10.0.1.214` automatically through the SFP.

The status capture shows `S_LINK_OK`, transmitted full-duplex ability and ACK,
and both timers stopped at `0x001312d0` (1,250,000 cycles). Raw RX/TX idles
are correctly paired, with no sampled decoder errors and RX buffer status
zero. Initial ping runs lost 19/20 small packets and 6/20 full-MTU packets;
a later settled-link test passed 60/60 small and 30/30 full-MTU pings.
The cause of the initial losses is not established. Do not infer managed
switch forwarding delay without its port state/configuration.

The managed-switch operator observed its cumulative RX-error count move
from 802 to 803 during bring-up. The operator subsequently confirmed that
the counter remained at 803, with no further increments since the previous
check. This is an operator observation without a timed soak interval.
The KR260 MAC accumulated one RX FCS/error
count among 1,325 accepted frames, with no overflow, during the first run.
That counter combines CRC failure, GMII RX error and short frames; it is
not a pure CRC-only measurement. Sustained error-free operation and reliable
startup across implementations remain open checks. The additional probes
change placement; success of the instrumented image does not explain the
previous image's restart loop.

A second fresh JTAG boot of the instrumented image again acquired
`10.0.1.214`. Its small-ping run received 50/60: sequence 1 worked, 2–11 were
lost, and 12–60 all worked. The following full-MTU test passed 30/30. At the
end, PCS_STATUS=7 and LINK_STATUS=0x30; MAC counters showed 653 accepted RX
frames, zero RX FCS/error counts, zero overflow, and 129 TX frames. No manual
module reset was needed on either successful boot. The board is left running
this image; persistent boot flash was not modified.

Local ignored evidence is under `build/gem1_debug/sfp/`: `an_debug_uart.log`,
`reboot_uart.log`, `pass_ping_settled.log`, `pass_ping_large_settled.log`,
`reboot_ping_small.log`, `reboot_ping_large.log`, `pass_mac_final.log`,
`reboot_mac_final.log`, ILA CSVs and timing/DRC reports. The matching bitstream,
probes and routed checkpoint are preserved under `basic_connectivity/`.
The source, tests, debug scripts and documentation are recorded in the
`20260920-all_ports_passing_dhcp_ping` milestone. Generated hardware artifacts
and raw captures remain local and ignored.

## Rebuilding after changing the GTH XCI

`generate_target all` alone did not refresh the local out-of-context GTH
checkpoint during this investigation. In an existing project, explicitly
rebuild that run before linking the board synthesis result:

```tcl
open_project build/vivado_kr260/kr260_switch.xpr
set_property CONFIG.ENABLE_COMMON_USRCLK 2 [get_ips gth_sfp_ip]
set_property CONFIG.RX_EQ_MODE LPM [get_ips gth_sfp_ip]
generate_target all [get_ips gth_sfp_ip]
reset_run gth_sfp_ip_synth_1
launch_runs gth_sfp_ip_synth_1 -jobs 8
wait_on_run gth_sfp_ip_synth_1
```

Re-synthesize the board when RTL has changed. Open the board synthesis run,
read the implementation-only clock and RGMII constraints, and write a linked
checkpoint for `build/debug_sfp.tcl`. It verifies TXOUTCLK drives the user
clock helper before adding the ILAs. Use the resulting matching `.bit` and
`.ltx` files for programming and capture. The normal clean-project build
imports the repository XCI; this caveat concerns reuse of the local project.

## Intermittent packet loss with an attached endpoint

After the milestone, the operator reported a stall followed by spontaneous
recovery. The SFP remained the uplink and right-upper GEM0 connected to endpoint
`10.0.1.140`, not to the same managed switch. The CPU retained `10.0.1.214`.
R5 tick/timestamp counters advanced, DMA showed no errors, and GEM0 reported
no TX underrun, RX FCS error or RX overrun. Both links stayed active
(`LINK_STATUS=0x31`, `PCS_STATUS=7`).

Small CPU pings passed 120/120, but full-MTU loss varied widely: separate
CPU runs received 2/30, 149/150, 137/180 and 180/300. The forwarded endpoint
received 11/30 full-MTU pings. The SFP MAC RX error counter increased while
its overflow counter remained zero. This is evidence of intermittent receive
corruption rather than a confirmed processor or fabric hang.

Raw GTH ILA captures caught expected payload byte `0x73` decoded as `0x93`,
with RXCHARISK, RXDISPERR and RXNOTINTABLE asserted on that byte. It occurred
in both low and high byte lanes in separate captures. RXBUFSTATUS stayed
zero throughout those corrupt captures. Other captures contained complete
1518-byte ICMP requests with valid CRCs. Thus at least part of the loss
originates at the serial receiver/decoder, before PCS frame parsing.

The Wizard's previous `RX_EQ_MODE=AUTO`, with a 20 dB insertion-loss
assumption, generated DFE mode (`RXLPMEN=0`).
[AMD UG576, RX equalizer](https://docs.amd.com/v/u/en-US/ug576-ultrascale-gth-transceivers)
recommends LPM for low-loss channels and repetitive, unscrambled 8b/10b
traffic; DFE automatic adaptation can drift with repeated patterns. This is
a candidate explanation for the observed corruption and self-recovery,
not a direct measurement of the equalizer's internal state.

The repository XCI now explicitly selects `RX_EQ_MODE=LPM`. Comparing
Wizard-generated primitive configurations produces exactly these differences:

| Setting | Previous DFE | LPM |
| --- | --- | --- |
| RXLPMEN | 0 | 1 |
| RX_SUM_IREF_TUNE | 0x9 | 0x4 |
| RX_SUM_VCMTUNE | 0xa | 0x6 |

Local evidence is under `build/gem1_debug/stall_investigation/`.
In particular, `rx_aligned_1.csv` and `rx_aligned_2.csv` contain the decoder
faults; `lpm_delta.json` records the Wizard attribute comparison.
The previous image/checkpoint/probes are preserved under `pre_lpm/`.

### Test-host ARP ambiguity

The test workstation has Ethernet `10.0.1.24` (MAC
`c8:ff:bf:0f:6e:4f`) and Wi-Fi `10.0.1.14` (MAC
`88:f4:da:9f:ec:b4`) on the same subnet. With LPM loaded,
`ping -I eth1` to the endpoint initially received 0/300 despite no MAC
errors. Five raw SFP TX captures showed complete, CRC-valid ICMP echo replies
from `10.0.1.140` to `10.0.1.24`, addressed to the workstation's
**Wi-Fi MAC**. These are in `build/gem1_debug/lpm/endpoint_tx_*.csv`.

The host has `arp_ignore=0` on both interfaces and globally, permitting
ARP replies for an address on another interface, as described in the
[Linux IP sysctl documentation](https://kernel.org/doc/html/latest/networking/ip-sysctl.html).
An interface-bound ping can miss replies arriving through the other interface.
Repeating the test without `-I eth1` restores responses; route lookup still
selects Ethernet and source `10.0.1.24` for outgoing requests.
No host network configuration was changed. Earlier interface-bound loss
figures are therefore not reliable measures of FPGA packet loss by
themselves. The independently captured GTH decoder errors remain valid evidence.

### LPM implementation and hardware validation

For a controlled comparison, the first LPM debug image applies precisely the
three Wizard-generated differences above to the preserved routed checkpoint.
RXLPMEN is tied to the same constant-one net as RX8B10BEN. This retains the
existing logic, probes and 900 ps PL0 IDELAY override. Routing and bitstream
DRC passed; setup/hold slack remains +0.018/+0.012 ns. The existing project's
GTH output products and OOC synthesis checkpoint were also regenerated with
LPM explicitly selected.

The LPM image is `build/gem1_debug/lpm/sfp_lpm.bit`, with matching
`sfp_lpm.ltx` and `routed.dcp`. It was loaded using
`software/r5/boot_jtag.tcl`, resetting the receiver and PS through the normal
volatile bring-up sequence. DHCP acquired `10.0.1.214` automatically;
GEM0 and SFP subsequently reported link up (`0x31`).
The first CPU test received 276/300 full-MTU pings: only sequences 2–25 were
lost, with all 26–300 received. This initial interruption remains unexplained.
The next CPU test with full-MTU repeated `0x73` payload passed 300/300.

The unbound endpoint test passed 300/300 full-MTU pings. After at least
60 seconds without generated ping traffic (ordinary LAN background traffic
remained), another simultaneous pair of tests passed 300/300 to the CPU
with the default payload and 300/300 to the endpoint with repeated
`0x00` payload. Thus the settled tests received 600/600 full-MTU replies
from each address, across two payload patterns per target.

Final SFP counters were 5,687 accepted RX frames, zero RX FCS/error counts,
zero overflow and 2,836 TX frames. PCS_STATUS remained 7 and LINK_STATUS
0x31. R5 timers continued advancing at the expected rates and DMA status
showed no errors. Logs are in `build/gem1_debug/lpm/`:
`cpu_large.log`, `cpu_pattern73.log`, `endpoint_unbound.log`,
`cpu_after_idle.log`, `endpoint_after_idle.log`, `mac_final.log`,
`status_final.log` and `uart.log`.

These results support keeping LPM for this module/channel and traffic pattern.
They do not prove DFE adaptation was the sole cause of all prior losses,
nor establish long-duration reliability or explain the brief initial
interruption. The board is left running LPM; persistent boot flash is unchanged.

## Debug instrumentation removed (2026-09-21)

The normal project was rebuilt with LPM and ingress-port exclusion on
destination lookup hits, without inserting ILAs or a debug hub. It was
loaded and passed DHCP plus 300/300 full-MTU pings to each of the CPU and
GEM0 endpoint, with zero SFP MAC receive errors. This supersedes the running
LPM debug image above. See [normal-image validation](verification.md#normal-image-without-debug-ilas-2026-09-21).
Historical debug scripts, images and captures remain available for reference.
