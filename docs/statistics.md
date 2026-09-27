# Statistics and environmental monitoring

Implemented 2026-09-21. Packet counters are standard hardware; DDR and debug
instrumentation are independently selectable at synthesis time. The R5 owns
all destructive statistics reads and accumulates the results in cacheable DDR.

## Network readout

The R5 exposes accumulated counters and sensor snapshots through a read-only
SNMPv2c agent. See [snmp.md](snmp.md) for query examples, the custom MIB,
validity checks and configuration. SNMP does not clear hardware counters.

## Build selection

| Category | Hardware option | R5 option | Default |
| --- | --- | --- | --- |
| 1: port packets and bytes | Always included | Always included | On |
| 2: fabric DDR transfers | `STATS_DDR=1` | `STATS_DDR=1` | Off |
| 3: internal debug events | `STATS_DEBUG=1` | `STATS_DEBUG=1` | Off |
| Temperature, voltage, SOM power | Existing hard AMS and PS I2C1 | Included | On |

For example, to enable both optional categories:

```sh
STATS_DDR=1 STATS_DEBUG=1 /tools/Xilinx/2026.1/Vivado/bin/vivado \
  -mode batch -source build/build_kr260.tcl -tclargs synth
make -C software/r5 STATS_DDR=1 STATS_DEBUG=1
```

Omit the options for the standard build. The hardware script sets matching parameters on the catalog fabric and
management cells in the production block design.
Changing R5 options updates a configuration dependency and rebuilds objects;
a clean build is not required. Complete implementation/timing checks before
programming a new image.

At startup, firmware compares the complete ABI/capability word against its
build options. A mismatch prints a diagnostic and disables counter collection;
network operation and environmental monitoring continue. This also protects
against accidentally running new firmware with an older FPGA image.
Legacy MAC diagnostic registers remain compatible and independent of this
new read/clear interface.

## Category 1: port counters

All six ports have eight counters in this order:

| Slot | Counter |
| ---: | --- |
| 0 | RX good packets |
| 1 | RX bad packets |
| 2 | RX good bytes |
| 3 | RX bad bytes |
| 4 | TX good packets |
| 5 | TX bad packets |
| 6 | TX good bytes |
| 7 | TX bad bytes |

Port numbering remains GEM0=0 (right upper), GEM1=1 (right lower), PL0=2
(left upper), PL1=3 (left lower), SFP=4, CPU=5. RX means into the switch;
for the CPU virtual port, RX therefore means R5-to-fabric.

A byte counter counts **all observed bytes belonging to the corresponding
class of completed frame**, not just bytes containing bit errors. Normal
physical-port counts exclude preamble, SFD, FCS and interpacket gap; successful
physical TX includes MAC padding. A flood produces a separate TX count for
each destination that actually transmits it. Forwarding-policy drops are not
MAC receive errors.

Measurement boundaries and limitations:

- GEM RX observes the external FIFO before the bridge. `rx_w_err`, bridge
  overflow and a mid-frame flush classify a frame as bad. A flush counts the
  bytes delivered before the abort. Frames the GEM never presents on its FIFO
  cannot be counted by this observer.
- GEM TX uses the GEM frame-completion toggle and status bits, rather than
  assuming that supplying the last byte means success. Failed-TX bytes are
  bytes supplied to the GEM, not an estimate of bytes successfully put on the
  wire. This observer targets the current full-duplex configuration.
- PL/SFP RX counts accepted frames as good and rejects as bad, including
  CRC/code/length errors and receive-buffer exhaustion. Bytes are observed
  after SFD, with four trailing FCS bytes excluded when available. On severely
  truncated frames the receiver cannot establish whether those trailing bytes
  really were FCS. Activity without recognizable SFD is not a packet.
- PL/SFP TX counts completed MAC transmissions. These MACs store complete
  frames before transmission and do not generate underrun/error frames;
  their on-wire bad-TX counters are consequently zero. Pre-transmission
  oversized-frame rejection remains visible in the legacy MAC counters.
- CPU counters observe accepted AXI-stream beats, honor `TKEEP`, and classify
  malformed keeps and lengths outside the current R5's 14–1514-byte packet
  contract as bad. There is no FCS or MAC padding at this boundary. These are
  transport counters, not acknowledgements of software processing or forwarding.

Counters reset with their source-domain reset. An in-progress frame that is
lost during reset is not retained as a completed packet.

## Category 2: fabric-to-DDR instrumentation

There are four independent monitors, all in the 125 MHz fabric clock domain:

| Bank | Path | Direction |
| --- | --- | --- |
| 8 | Shared physical ingress engine | Fabric → DDR packet pool |
| 9 | Shared physical egress engine | DDR packet pool → fabric |
| 10 | CPU-port RTL write engine | CPU stream → DDR packet pool |
| 11 | CPU-port RTL read engine | DDR packet pool → CPU stream |

These observe the RTL masters before the HP0 interconnect. They do not include
the separate vendor AXI DMA's descriptor/bounce-buffer accesses through HP1.

Each monitor provides:

| Slot | Measurement | R5 aggregation |
| ---: | --- | --- |
| 0 | Accepted data bytes | Sum |
| 1 | Completed bursts | Sum |
| 2 | Sum of completed-burst latency, in fabric clocks | Sum |
| 3 | Maximum completed-burst latency, in fabric clocks | Maximum |
| 4 | Address-channel `VALID && !READY` cycles | Sum |
| 5 | Data-channel `VALID && !READY` cycles | Sum |
| 6 | Accepted error responses (`SLVERR` or `DECERR`) | Sum |
| 7 | Cycles with an outstanding burst | Sum |

Latency runs from accepted AW/AR through accepted B/final R, inclusive.
It excludes waiting before the address handshake; address stalls are reported
separately. An active burst's age survives polling, and its complete latency
is recorded when it finishes. These monitors rely on the existing engines'
one-outstanding-burst-per-direction contract. Extend the monitor if the
engines are changed to allow multiple outstanding transactions.

Write bytes use `WSTRB`; read bytes count the full 16-byte accepted beat,
including unused trailing lanes. Counts describe traffic at the AXI interface,
not Ethernet payload bytes or internal DDR-controller bus utilization. A read
error counts per accepted erroneous response beat; a write error counts per B.

Average completed latency is latency sum / burst count, divided by the
hardware-reported fabric frequency (8 ns per cycle at 125 MHz).
DDR bandwidth is the change in byte totals / elapsed time. Polling individual
registers introduces small boundary skew; these are not an atomic bank snapshot.

## Category 3: debug instrumentation

Bank 12 has sixteen counters in the fabric clock domain:

| Slots | Measurement |
| --- | --- |
| 0–4 | Physical-port ingress stream backpressure cycles, ports 0–4 |
| 5–9 | Physical-port egress stream backpressure cycles, ports 0–4 |
| 10 | CPU-to-fabric stream backpressure cycles |
| 11 | Fabric-to-CPU stream backpressure cycles |
| 12 | CPU buffer-allocation request waiting for grant, cycles |
| 13 | CPU enqueue request waiting for grant, cycles |
| 14 | Link-down flush busy cycles |
| 15 | Sum of accepted AXI errors across the four RTL master directions |

These help distinguish downstream congestion, buffer-manager stalls and DDR
faults. Backpressure is a cycle count, not a packet-drop count. The existing
MAC error/overflow counters, link-event flags and RGMII elastic-buffer sticky
flags remain available through their existing interfaces.

## Widths, read/clear and ownership

| Counter family | Hardware payload width | Half-second upper bound |
| --- | ---: | --- |
| Port counts | 27 bits | 62.5 million bytes per 1 Gb/s direction; CPU stream at most 125 million bytes at 16 bits × 125 MHz |
| DDR counts | 30 bits | 1,000 million bytes per 128-bit × 125 MHz direction; 62.5 million clocks |
| Debug counts | 28 bits | 62.5 million cycles; at most 250 million combined AXI error events |

The port width also accommodates malformed tiny-frame event rates. Individual
completed-frame updates can carry bytes from just before the polling boundary.
The sizing leaves headroom for ordinary maximum-sized frames. A pathological
very long transaction can saturate a latency sum when it finally completes.

Each source-domain counter saturates, rather than wrapping. Readback bit 31
indicates saturation; bits 30:0 contain its zero-extended value. Saturated
results are lower bounds, and R5 increments `saturated_reads`. A read clears
both value and overflow indication. An event on the exact capture cycle goes
into the **next** interval, so it is neither lost nor double-counted.

Read/clear occurs once when the source captures the processor's DATA read
request. A four-phase request/acknowledge mailbox crosses clock domains. The
source holds the captured value stable; AXI read-data backpressure never
causes a second clear. Request/ack flops have `ASYNC_REG` attributes; bundled
select/data paths are delay-bounded by the board CDC constraints.

**Only the R5 statistics task should read DATA.** JTAG tools or other tasks
must use the software snapshot API instead. Otherwise they steal counts from
the accumulator. The interface does not provide a globally simultaneous
snapshot across ports, directions or packet/byte counters.

R5 polls at 250 ms using `vTaskDelayUntil`, accumulating additive counters in
64-bit values and maximum-latency counters by maximum. `late_polls` records
poll starts more than 500 ms apart. There is no hard scheduling guarantee:
saturation and timeout flags make missed intervals visible. Each bank now has an independent management-domain mailbox. If a source
clock stops, the AXI DATA access returns a timeout sentinel after approximately
28.7 us (4,095 control clocks). Only that CPU access ends: the source request,
selected slot and any captured result remain owned by that bank. Other banks
continue collecting. Firmware retries each unavailable bank on its next 250 ms
poll without a software BUSY loop. A captured result is consumed exactly once,
even if the source clock stops after asserting ACK; its slot cannot change until
source ACK release. An R5-only restart discovers and drains the hardware's pending
slot before beginning a new scan. Independent source resets during a read still
require coordinated recovery and are not made lossless by this change.

Every source bank exports a registered four-bit Gray progress counter, independent
of packet traffic. Two management-domain synchronizer stages monitor progress.
After 2,048 unchanged control samples (about 14.3 us), the clock is classified as
unavailable. The implemented source clocks are at most 125 MHz, below the
142.857 MHz monitor clock; existing 7 ns source-to-control CDC maximum-delay
bounds limit Gray-bus skew to less than one source period. New rates require
rechecking that bound and the monitor sampling rate. A clock gap while a read is
pending is sticky until the next transaction. This helps classify a timeout even
if clocking resumes before firmware reads status. A held source reset also stops the progress counter; unavailable therefore
means no observed source progress, not a physical clock-stop measurement.
Clock activity alone does not prove mailbox logic is healthy.

`bank[13]` health reports distinguish absent (0), current (1), unavailable clock /
stale totals (2), active-clock read fault / stale totals (3), and not sampled (4).
Each bank exposes its last complete collection age, observed clock-unavailable
episodes, active-clock timeout attempts and hardware status. Retained totals
remain visible; a partial bank pass does not advance its completion timestamp.
Clock-unavailable episodes count state transitions observed by the collector,
not every physical clock stop. Legacy `read_timeouts` and per-index release /
response diagnostics now count active-clock faults only. Optional banks absent
from the matching build are marked absent. ABI mismatch disables all collection.

The independent mailbox ABI is **0x53540200**, with capability bits 0=ports,
1=DDR and 2=debug. It requires matching hardware and firmware; no compatibility
with the former shared-mailbox ABI is provided. Source counter widths are
unchanged; saturation remains visible if collection is delayed excessively.

## Register interface

The interface extends the existing diagnostic aperture at `0x80100000`:

| Offset | Register | Semantics |
| --- | --- | --- |
| `0x24` | ABI/capabilities | `0x53540201` standard; bit 1 DDR, bit 2 debug; ABI version 1 in bits 15:8 |
| `0x28` | INDEX | Bits 7:4 bank, bits 3:0 slot; writable only when idle |
| `0x2C` | DATA | Read/clear selected counter; `0xFFFFFFFF` means timeout, not a count |
| `0x30` | BUSY | Bit 0 CPU access active, bit 1 result acknowledgment; not source-bank busy |
| `0x34` | FABRIC_HZ | `125000000` |

`0x38` is the selected bank's read-only status: bit 0 pending, bit 1 ready,
bit 2 source ACK release busy, bit 3 clock progressing, bits 7:4 retained slot,
bit 8 clock gap during the retained transaction. INDEX may select a different
bank while another is pending; selecting a different slot within the pending
bank cannot cancel or retarget its read. `0x30` describes the CPU-side access,
not all source requests.

Banks 0/1 are GEM0 RX/TX, banks 2/3 GEM1 RX/TX, each with four
slots (good packets, bad packets, good bytes, bad bytes). Banks 4/5/6/7 are
PL0/PL1/SFP/CPU, each with all eight slots. Banks 8–12 are described above.
Unimplemented slots/banks return zero. A disabled optional bank also returns
zero; consult capabilities rather than inferring support from zero counts.

After DATA times out, INDEX can select another bank. To retry the original
bank, use the retained slot from BANK_STATUS (0x38); never substitute a
different slot for a pending destructive read. A coordinated hardware
reset discards counters and mailbox state; firmware totals must be treated as
a new measurement epoch when restarting the whole design.

## Temperature, voltage and power

The R5 samples sensors every second in a separate, lower-priority task. It
uses the existing hard PS/PL SYSMON blocks through AMS at `0xFFA50000`, with
continuous channel sequencing. No additional soft ADC or AXI monitor IP is
needed. Existing alarm thresholds and channel selections are preserved;
firmware adds temperature and three supply channels for each block.

| Source | Measurements |
| --- | --- |
| PS SYSMON | PS temperature, VCC_PSINTLP, VCC_PSINTFP, VCC_PSAUX |
| PL SYSMON | PL temperature, VCCINT, VCCAUX, VCCBRAM |
| INA260 U14 | SOM input voltage, signed current, power on SOM_5V0 |

AMD documents the hard monitor's default operation without a PL instance in
[UG580](https://www.amd.com/content/dam/xilinx/support/documents/user_guides/ug580-ultrascale-sysmon.pdf)
and the SOM rail mapping in
[UG1091](https://docs.amd.com/r/en-US/ug1091-carrier-card-design/Voltage-Rail-Monitoring).

The carrier power monitor is on PS I2C1 (`0xFF030000`, MIO24/25), address
`0x40`, without an I2C mux. This connection is recorded in AMD's
[KR260 device tree](https://raw.githubusercontent.com/Xilinx/linux-xlnx/master/arch/arm64/boot/dts/xilinx/zynqmp-sck-kr-g-revB.dtso).
It measures the **SOM supply**, not total 12 V input power or individual carrier
loads; see [UG1092 power telemetry](https://docs.amd.com/r/en-US/ug1092-kr260-starter-kit/Powering-the-Starter-Kit-and-Power-Budgets).

The driver checks INA260 manufacturer/die IDs, selects continuous conversion
with 16-sample averaging and 1.1 ms conversions, and requires conversion-ready
without arithmetic overflow before publishing. Scaling is 1,250 µV/LSB,
1,250 µA/LSB signed current, and 10,000 µW/LSB power, per the
[TI INA260 datasheet](https://www.ti.com/lit/ds/symlink/ina260.pdf).
Each short I2C transaction has a 2 ms deadline. Missing sensors/NACKs/timeouts
invalidate the sample and increment the error count; they do not block packet
statistics collection. The sensor task is the runtime owner of PS I2C1.

Sensor readings are gauges, not cumulative/read-clear event counters. The
snapshot contains milli-degrees Celsius, microvolts, microamps, microwatts,
a timestamp and a validity mask (bit 0 PS, bit 1 PL, bit 2 INA260). Never treat
an invalid retained value as a new valid measurement. Channels are sampled
sequentially, not at one globally atomic instant.

## Software access and verification

[`statistics.h`](../software/r5/include/statistics.h) defines
`statistics_get()` and `sensors_get()`. These copy software snapshots under
an RTOS critical section, including 64-bit totals safely on the 32-bit R5.
The underlying objects occupy normal cacheable BSS in the existing R5 DDR
reservation; they are not DMA buffers. Direct PSU JTAG reads can see stale
DDR while R5 data is dirty in cache.

Verification for this change is recorded in [verification.md](verification.md).
The all-counter image has completed place-and-route and bitstream generation
with final WNS +0.018 ns and WHS +0.010 ns. Matching firmware and hardware
artifacts are preserved under `build/r5/statistics_artifacts/`. They were loaded
through JTAG on 2026-09-21: DHCP and full-MTU R5/forwarded-endpoint pings passed.
Numerical sensor/counter accuracy and sustained polling validation remain pending.

The processor reads `FABRIC_HZ` and publishes it as HTTP `fabric_hz` and SNMP
`krFabricHz` (health scalar 15). At 125 MHz a DDR/debug cycle is 8 ns.
The TTC timestamp frequency is separate and unchanged. Future widening of the
SFP packet interface to 128 bits requires a new port-byte counter width review.
