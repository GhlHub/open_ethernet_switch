# SNMP statistics access

The R5 runs a read-only SNMPv2c agent on IPv4 UDP port 161. It supports GET,
GETNEXT and GETBULK (`snmpget`, `snmpwalk`, `snmpbulkwalk`). SET is rejected.
The default community is `public`. SNMPv1, SNMPv3, traps and configuration
writes are not implemented. SNMPv2c exposes the community and values in clear
text; use it on the trusted lab network. SNMPv3 is the future option for
authenticated/encrypted management.

The agent reads the processor's accumulated statistics through
`statistics_get()` and `sensors_get()`. It never reads or clears hardware
counter DATA registers. Repeated queries do not reset totals. The existing
250 ms statistics collector and 1 s sensor task remain the data owners.

## Reader script

From the repository root:

```sh
# One labeled snapshot of all counters, collection health and sensors.
python3 scripts/read_snmp_counters.py

# Poll every second; stop with Ctrl-C.
python3 scripts/read_snmp_counters.py 10.0.1.214 --interval 1

# Ten samples as newline-delimited JSON, suitable for logging.
python3 scripts/read_snmp_counters.py --interval 1 --count 10 --json > counters.jsonl
```

The script uses Python 3's standard library and Net-SNMP `snmpbulkwalk`.
It finds the command on PATH, or uses the local copy under
`build/r5/snmp_tools/` on this workstation. On another Ubuntu/Debian host,
install the `snmp` package. `--snmpbulkwalk PATH` selects another executable;
`--community` (or `SNMP_COMMUNITY`) and `--enterprise` override lab defaults.

Displayed counters are accumulated totals, not interval deltas or rates.
Optional DDR/debug tables are detected automatically. Sensor units are
converted to Celsius, volts, amperes and watts; invalid readings are shown
as `n/a` (JSON `null`). Health warnings accompany unavailable collection,
saturation and mailbox timeouts. Each walk spans multiple requests and is
not an atomic snapshot. A failed read prints an error and exits nonzero.

## Quick start

With Net-SNMP installed on a management workstation, no MIB installation is
needed for numeric queries. Substitute the current DHCP address if it changes:

```sh
# All project objects, including optional counters compiled into firmware.
snmpbulkwalk -v2c -c public -Cr10 -On 10.0.1.214 .1.3.6.1.4.1.32473.1

# Collection health: availability, saturation count and read timeouts.
snmpget -v2c -c public -On 10.0.1.214 \
  .1.3.6.1.4.1.32473.1.1.1.0 \
  .1.3.6.1.4.1.32473.1.1.5.0 \
  .1.3.6.1.4.1.32473.1.1.6.0

# Port table: names, link states and all eight counters per port.
snmpbulkwalk -v2c -c public -On 10.0.1.214 .1.3.6.1.4.1.32473.1.2

# Temperature, voltage and SOM current/power (check validity mask first).
snmpwalk -v2c -c public -On 10.0.1.214 .1.3.6.1.4.1.32473.1.5
```

Load [KR260-SWITCH-MIB.txt](mibs/KR260-SWITCH-MIB.txt) into your manager for
symbolic names. Its standard dependency is `SNMPv2-SMI`:

```sh
snmpget -M +./docs/mibs -m +KR260-SWITCH-MIB -v2c -c public 10.0.1.214 \
  KR260-SWITCH-MIB::krPortRxGoodPackets.1 \
  KR260-SWITCH-MIB::krPsTemperature.0 \
  KR260-SWITCH-MIB::krSensorValidMask.0
```

## OID map

`B = 1.3.6.1.4.1.32473.1`. Enterprise **32473 is the RFC 5612 example
number**, approved for this initial lab implementation. It is not a project
PEN. Replace `SNMP_ENTERPRISE` in `software/r5/include/snmp.h` and the MIB's
module identity with an assigned PEN before deployment. The read community
is configured by `SNMP_COMMUNITY` in that header (1–64 bytes). Header changes
are tracked by the firmware build dependencies. Do not log the community.

| Subtree | Meaning |
| --- | --- |
| `B.1.<field>.0` | Collection health and build capabilities |
| `B.2.1.<column>.<port>` | Six-port packet/byte table |
| `B.3.1.<column>.<direction>` | Optional fabric DDR instrumentation |
| `B.4.1.<column>.<event>` | Optional debug events |
| `B.5.<field>.0` | Environmental readings and sensor health |
| `B.6.1.<column>.<bank>.<slot>` | Timeout counts by hardware counter location |

Port row indices are **one-based**: 1 GEM0/right upper, 2 GEM1/right lower,
3 PL0/left upper, 4 PL1/left lower, 5 SFP, 6 CPU. Columns 1 and 2 are name
and link state (`up=1`, `down=2`). Columns 3–10 are RX good packets, RX bad
packets, RX good bytes, RX bad bytes, TX good packets, TX bad packets,
TX good bytes, TX bad bytes. All eight totals are `Counter64`.
RX means **toward the fabric**, including R5-to-fabric for CPU RX.

DDR rows 1–4 are physical ingress write, physical egress read, CPU write,
CPU read. Column 1 is name; columns 2–9 are bytes, completed bursts,
latency cycle sum, maximum latency cycles, address stalls, data stalls,
error responses, outstanding cycles. Maximum latency is a `Gauge32`
maximum **since R5 restart**; all other metrics are `Counter64` sums.
DDR cycles are at 100 MHz; mean latency in seconds is
`delta(latencyCycles) / delta(completedBursts) / 100000000` when bursts > 0.

Debug columns are 1 name and 2 `Counter64` total; rows 1–16 match slots
0–15 in [statistics.md](statistics.md). This also documents the precise
packet, byte, error and stall definitions for all three categories. These
custom counters are not presented as IF-MIB unicast or discard counters:
the hardware does not provide those exact distinctions.

Collection health fields 1–9: availability (`1=available`, `2=unavailable`),
hardware capability word, attempted polls, late polls, saturated reads,
read timeouts, collection timestamp age in ms, PS timestamp frequency in Hz,
and firmware build bits (`1=ports`, `2=DDR`, `4=debug`).
Fields **10 and 11** (added 2026-09-22) are `Counter32` timeout counts:

- `krStatsMailboxReleaseTimeouts.0`: R5 exceeded the approximately 100 us
  BUSY-release wait before selecting a counter. Elapsed time includes any
  preemption of the statistics task; this does not prove the hardware stayed
  busy for the entire interval.
- `krStatsSnapshotResponseTimeouts.0`: DATA returned the hardware timeout
  sentinel after approximately 27.3 us waiting for snapshot acknowledgment.
  Firmware retains and retries the same pending counter index.

`krStatsReadTimeouts.0` remains the combined total, equal to the sum of these
two classes modulo 2^32. All reset on R5 restart. Existing OIDs are unchanged.
The reader script displays both new fields (null with older firmware).

Fields **12–14** record the most recent timeout locations:
`krStatsLastReleaseIndex`, `krStatsLastReleaseTargetIndex`, and
`krStatsLastResponseIndex`. Each is the raw hardware index (`bank * 16 + slot`);
4294967295 means no event since restart. Release index is read from the active
hardware INDEX register; release target is the next index firmware wanted
to select. A response timeout records the selected/requested index.

The new `B.6.1.<column>.<bank>.<slot>` table exposes a Counter32 per timeout
class for every compiled-in hardware counter: column 1 release, column 2
snapshot response. Both bank and slot are **zero-based**, matching the hardware
register interface. Values count timeout attempts, including repeated retries.
Release counts are attributed to the active hardware index. Each class's table
sum matches its scalar total modulo 2^32 for valid indices; queries spanning
multiple collection intervals can temporarily differ. No new destructive
hardware counter reads are introduced.

```sh
# All snapshot-response counts, indexed by bank and slot.
snmpwalk -v2c -c public -On 10.0.1.214 .1.3.6.1.4.1.32473.1.6.1.2

# Most recent response-timeout index.
snmpget -v2c -c public -On 10.0.1.214 .1.3.6.1.4.1.32473.1.1.14.0
```

Banks 0–3 are GEM0 RX, GEM0 TX, GEM1 RX, GEM1 TX (slots 0–3);
4–7 are PL0, PL1, SFP, CPU (slots 0–7); 8–11 are physical DDR write/read
and CPU DDR write/read (slots 0–7); bank 12 is debug (slots 0–15).
Slot definitions follow [statistics.md](statistics.md). The reader script
prints nonzero table rows with source/counter names and decodes the last indices
into bank and slot. JSON `timeouts` contains only nonzero rows; an empty list
means no per-index events, or the table is absent on older firmware.

Optional tables are
absent when not compiled in. If the hardware capabilities disagree with the
firmware, availability is false and the collector is disabled; do not use
the displayed totals. Timeouts may mean partially updated totals; a nonzero
saturation count means accumulated counters may be lower bounds.

Sensor fields 1–14: validity mask, error count, sample age in ms, PS and PL
temperature in millidegrees Celsius, six voltages in microvolts (PS LP, FP,
AUX; PL INT, AUX, BRAM), signed SOM current in microamperes, SOM voltage in
microvolts, SOM power in microwatts. Validity bit 0 covers PS, bit 1 PL,
bit 2 INA260; **ignore readings whose validity bit is clear**. SOM power is
not whole carrier-board power. An age of 4294967295 means unknown/saturated.

Standard system objects provided: `sysDescr.0`, `sysObjectID.0`,
`sysUpTime.0` (hundredths of a second since SNMP task start), `sysName.0`.
This is a deliberately limited system subtree, not a full SNMPv2-MIB/IF-MIB
implementation. Totals reset on R5 restart; a manager should track uptime
and discard rate deltas spanning a restart. TimeTicks naturally wraps after
about 497 days. Hardware collection and whole walks are not globally atomic.

## Build and verification

```sh
make -C software/r5 STATS_DDR=1 STATS_DEBUG=1
make -C software/r5 test
```

Match the counter flags to the FPGA image. SNMP is included in all R5 builds;
no FPGA rebuild is needed to add this agent. The UDP task runs at priority 1,
below collection, PHY polling and packet handling. Each request gets copies
of the current software snapshots and one link-enable register read.

The BER engine has no heap allocation and is independent of FreeRTOS for
host testing. Limits: 1400-byte request/response datagrams, 32 request
varbinds, 24 OID components, 64 response varbinds. GETBULK truncates at the
response size/work limit; large GETs return `tooBig`. Malformed, unauthorized,
unsupported-version, or over-limit requests are discarded. Unknown objects
and instances and end-of-view use SNMPv2 exceptions. The agent's receive
queue is limited to four packets, and it yields after each datagram.
Other UDP sockets default to eight queued packets.

Host tests cover all four counter builds; signed values and full-range
Counter64; GET/GETNEXT/GETBULK; table ordering; SET rejection; exceptions;
size bounds; request IDs; truncated, overflowing and mutated BER messages.
See [verification.md](verification.md) for board validation results.

Protocol references: [RFC 3416](https://www.rfc-editor.org/rfc/rfc3416.html)
and [RFC 5612](https://www.rfc-editor.org/rfc/rfc5612.html).

## Observed issues

The latest 30-second observation recorded two historical mailbox read timeouts,
up from one during initial deployment; none occurred within that sample.
Collection continued at four polls per second without saturation or late polls.
The 2026-09-22 firmware separates release and snapshot-response timeouts
as described above. The subsequent per-index diagnostics record both classes
by bank/slot and retain the most recent timeout indices. A live response
timeout was observed before these location diagnostics were deployed; its
location cannot be recovered retrospectively.
See [live counter observations](verification.md#2026-09-21-live-snmp-counter-observation)
for packet, latency, backpressure and sensor results and their limits.
