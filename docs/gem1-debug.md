# GEM1 transmit ILA bring-up

The development KR260 is at `10.0.1.109:3121` (hardware server), with its
UART telnet bridge at `10.0.1.109:2323`. The DHCP network connects to the
**lower-right Ethernet connector**, identified during bring-up as GEM1,
DP83867 MDIO address 9 on GEM1's shared management bus.

The initial firmware received packets through GEM1 and virtual CPU port 5,
but TX underruns blocked DHCP. ILA captures isolated two faults; correcting
them enabled DHCP acquisition and ping. MM2S descriptor completion alone only
proves delivery to the fabric.

## Instrumentation

`build/debug_gem1.tcl` adds two ILAs to the existing synthesized design,
without adding RTL probe ports or rebuilding the PS block design. It
places/routes a separate image under ignored `build/gem1_debug/` and produces
`kr260_gem1.bit`, `kr260_gem1.ltx`, timing/DRC reports and checkpoints.
The debug hub uses the continuous PS 50 MHz clock. Probe inputs have one
pipeline stage; all signals within each ILA are sampled in their own domain.

| ILA | Clock | Depth | Signals |
| --- | --- | --- | --- |
| `ila_gem1_tx` | GEM1 TX FIFO clock | 8192 | GEM read, valid, SOP, EOP, data-ready, underflow, flushed, completion/ack toggles, byte data, four GEM status bits, XPM FIFO empty, high-byte pending, SOP state, 18-bit FIFO head, FIFO reset-busy and pending-read state |
| `ila_gem1_feed` | 100 MHz fabric clock | 2048 | 18-bit FIFO write data (`EOP`, upper-byte keep, 16-bit data), accepted write enable, FIFO full |

The transmit status outputs were previously unused and optimized out. The
script attaches their PS8 output pins to probe nets. No recovery behavior is
added by the instrumentation. Net names are checked explicitly; if synthesis
changes them, update the probe bindings rather than silently omitting probes.

## Build and capture

From the repository root, after the normal board synthesis and R5 build:

```sh
/tools/Xilinx/2026.1/Vivado/bin/vivado -mode batch -source build/debug_gem1.tcl \
  -log build/gem1_debug/build.log -nojournal
/tools/Xilinx/2026.1/Vitis/bin/xsdb software/r5/boot_jtag.tcl \
  tcp:10.0.1.109:3121 build/gem1_debug/kr260_gem1.bit halt
/tools/Xilinx/2026.1/Vivado/bin/vivado -mode batch -source build/capture_gem1.tcl \
  -log build/gem1_debug/capture.log -nojournal
```

Create `build/gem1_debug` before using it as Vivado's log directory. The boot
command resets the PS, runs the FSBL, programs the debug image, and leaves
R5-0 halted at entry. The capture script arms the fabric ILA on its first
accepted write and the GEM ILA on its first SOP, then starts R5-0. Both captures
retain 128 pre-trigger samples. It exports CSV and native ILA files for analysis.
The separate clock domains have independent sample indices; align them using
packet contents/events, not equal row numbers.

Inspect the byte stream accepted by GEM, its SOP/EOP positions, the first
underflow/status event, FIFO empty and flush/ack behavior. Compare transmitted
bytes against the packet entering the FIFO. This distinguishes input starvation,
byte/framing corruption, and an error occurring despite data availability.

## Captures and regression

The first two captures used identical PL logic and bitstream. Only
`IOU_SLCR.GEM_CLK_CTRL` differed:

| Observation | Original clock select (`0x006`) | PL-loopback clock select (`0x10e`) |
| --- | --- | --- |
| FIFO input / GEM response bytes | 314 / 314, identical | 314 / 314, identical |
| SOP / EOP sample | 128 / 441 | 128 / 449 |
| PL underflow sample | None | 450, immediately after EOP |
| PL flushed sample | None | 451 |
| GEM status | No transition | `0x8` at sample 458, cleared at 461 |
| Completion / acknowledgement toggle | Neither | Samples 458 / 459 |

The original clock configuration did not select the TX FIFO clock returned
through the PL BUFG, despite the generated PS wrapper connecting that return
clock. Firmware now sets GEM0/GEM1 FIFO clock selects (bits 3/8 at `0xff180308`)
while both MACs are disabled, preserving all other register bits. See
[AMD GEM_CLK_CTRL](https://docs.amd.com/r/en-US/ug1087-zynq-ultrascale-registers/GEM_CLK_CTRL-IOU_SLCR-Register).

With the clocks aligned, the capture shows an additional GEM read on the cycle
after EOP. The old adapter unconditionally reported an empty-FIFO read as an
underrun, even between frames. This asserts an error after the complete packet
has been supplied. The adapter now retains a boundary read until the next
permitted frame arrives; only emptiness after SOP is a mid-frame underrun.

A new regression sends a 314-byte frame followed by the observed trailing
read, waits with an empty FIFO, then sends a 17-byte frame. It verifies no
spurious underrun/flush and that the pending read receives exactly the next
SOP byte before further requests. The old RTL fails three checks; the updated
RTL passes the bridge and egress integration suites with both portable and
AMD XPM FIFO models. Existing mid-frame starvation/flush recovery also passes.

`python3 build/analyze_gem1.py [capture_directory]` compares the two captured
byte streams and reports framing, underflow, FIFO emptiness and status events.
Raw baseline captures and summaries are in ignored
`build/gem1_debug/baseline/` and `build/gem1_debug/clock_only/`.

## Corrected hardware result

With the pending-read RTL and loopback clock selection, the first DHCP
transmit capture contains 314 input/output bytes, identical byte for byte.
SOP/EOP occur at samples 128/449, with no underflow or flushed pulse.
GEM completion toggles at sample 461 and acknowledgement at 462; status
remains zero. Raw captures and the comparison are under ignored
`build/gem1_debug/fixed/`.

The UART reports `DHCP IPv4 acquired: 10.0.1.214`. Before ping, a live JTAG
sample records four successful GEM1 TX frames, zero TX underruns and 98 RX
frames. Five ICMP echo requests from host `10.0.1.24` (`eth1`) all succeed,
with 0.684–1.834 ms round-trip times. This verifies bidirectional GEM1 traffic
through the fabric and R5 CPU port, not sustained throughput or fault recovery.
Subsequent cable-move tests passed ping on the other three copper ports;
see [four-port results](verification.md#four-copper-ports-passing-dhcp-address-ping-2026-09-20).
DHCP renewal and fault recovery remain untested.

## Debug-image timing

The corrected RTL plus ILAs initially produced five PL0 RGMII RX hold
violations (worst −0.145 ns). The debug build sets the five existing PL0 RX
IDELAYE3 data/control delays to 900 ps instead of the board RTL default of
700 ps. This changes input sampling for the debug image only; it does not
relax timing constraints. Routed setup/hold slack is +0.018/+0.010 ns under
the existing constraints. The build rejects a negative setup or hold slack.
PL0 was disconnected and disabled during the initial GEM1 test. A later
cable move to PL0 passed 20/20 pings using this 900 ps debug setting. Sustained
receive testing and the remaining unconstrained/CDC paths still require
separate validation. PL1's 750 ps setting is unchanged.

The normal non-ILA bitstream must be rebuilt after changing the bridge RTL;
use the explicit debug bitstream argument above for this session. No flash
image was written.

The timing-corrected image was reloaded and captured again: the same 314-byte
match and successful completion were observed, DHCP again acquired
`10.0.1.214`, and another five pings passed (0.665–2.232 ms, zero loss).
Final evidence is in ignored `build/gem1_debug/final/`; the R5 is left running
this image.
