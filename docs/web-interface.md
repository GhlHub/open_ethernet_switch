# R5 web interface

The R5 serves a self-contained HTTP interface on TCP port 80 at its configured IPv4
address (DHCP by default). Viewing is public and uses no external assets.
Configuration changes require administrator credentials (factory `admin` / `admin`).
The current lab address after the permanent-MAC change is `http://10.0.1.104/`
(2026-09-24 DHCP lease).

- `/mac-table`: view the last completed MAC-table snapshot. **Refresh MAC
  table** is the only action that requests a hardware scan. There is no scan on
  page load and no periodic refresh. Columns show bank/row, MAC address,
  learned ports and remaining age at capture; age does not count down locally.
- `/configuration`: enable/disable GEM0 (right upper), GEM1 (right lower),
  PL0 (left upper), PL1 (left lower), and SFP. Physical link and effective
  forwarding state are displayed separately. Save writes port/IP preferences to microSD;
  Reload status fetches the latest settings without applying edits. Link and
  speed cells refresh every second without overwriting checkbox edits.
- `/statistics` (also `/`): refresh accumulated port counters, compiled-in
  DDR/debug counters, collector health, per-bank/slot timeout counts, and
  temperature/voltage/SOM power readings every second. Requests never overlap;
  failed requests mark the displayed information stale and polling continues.

Settings now persist in two files on the microSD card. Defaults enable all ports, request
GEM0 1000FD and other copper ports 10/100/1000FD, select SFP Auto and DHCP.
PL copper 10/100/1000 choices are active. The page marks higher SFP speeds as future;
unsupported-only selections disable admission. IP changes apply after restart.
The five permanent MACs and administrator username are displayed; stored
password verifiers are never returned. See [persistent configuration](configuration.md)
for storage layout, credentials, recovery and current hardware limits.
See [PS speed selection](ps-ethernet-speeds.md) and
[PL speed selection](pl-ethernet-speeds.md) for transition behavior.
For GEM1, PL0 and PL1, select the advertised speeds independently in
**Requested full-duplex speeds**. Selecting all three allows negotiation of
the highest common speed; selecting only 100 limits negotiation to 100 Mb/s.
At least one speed must remain selected. Save with administrator credentials
to persist and apply the selection. Changing the uplink's advertisement
briefly interrupts access while it renegotiates. GEM0 stays fixed at 1000 Mb/s.

The CPU virtual port is not administratively configurable. Disabling
ports changes MAC receive enables and masks the link task's desired fabric
ports. The existing link-clear/queue flush/MAC-learning flush sequence handles
removal. PHY negotiation remains active, so a disabled port can still report
physical link up. Already accepted/in-flight traffic can finish during the
transition; this is not an instantaneous packet-boundary isolation mechanism.
Changes are applied by the 250 ms link task. Re-enable follows its existing
flush-busy check and interval guard. PS GEM RX/TX are stopped while disabled;
PL/SFP reception is stopped and fabric egress destinations are removed/flushed.

Disabling the management uplink can disconnect the browser before it receives
the response. Recover through another enabled port or the documented JTAG
recovery build. Saved disables survive reboot; there is no automatic rollback.

Statistics use the same nondestructive `statistics_get` / `sensors_get` snapshots
as SNMP. The processor remains the sole reader of hardware clear-on-read
counters. Counter totals are encoded as decimal strings in JSON, preserving
all 64 bits in JavaScript. DDR/debug fields are omitted when not compiled in;
sensor validity and collector availability are visible. Voltage and current
readings use three decimal places (`1.800 V`, `0.800 A`); temperatures use one
(`30.0 °C`). DDR/debug cycles are
100 MHz fabric cycles (10 ns). CPU RX means CPU to fabric; TX means fabric to CPU.

## Concurrent request handling

The HTTP task accepts connections into an eight-entry queue, serviced by four
fixed workers. Each worker has its own 2 KiB request and 24 KiB response buffer
and a 16 KiB stack. FreeRTOS+TCP's listener capacity is 12 total child sockets,
including accepted clients; it previously allowed only two. The pool and queue
are bounded, so excess clients can still be refused or closed under overload.
Queued jobs older than two seconds are closed instead of accumulating work.
Receive/send calls retain 250 ms socket timeouts and the handler's overall
request, transmission and close deadlines remain bounded.

Configuration POSTs take a mutex across authentication and read/modify/save.
GET `/api/config` uses the same mutex because probing card writability touches
the single-owner USB/FAT stack. A two-second lock timeout returns HTTP 503;
statistics, port snapshots and HTML pages do not take this mutex. Failed
authentication releases it before the one-second penalty, so it occupies only
one worker. Response transmission and socket teardown happen after unlocking.

Read-only live regression (the POST case is deliberately unauthenticated and
must return 401 without changing settings):

```sh
python3 scripts/check_http_concurrency.py 10.0.1.104 --source 10.0.1.24
```

It tests two idle clients plus a third request, 120 mixed requests across six
clients, public reads during authentication rejection, recovery after exceeding
the connection limit, response length/type consistency and unchanged settings.
See [verification](verification.md) for board/browser results and traffic limits.

## HTTP API

| Method/path | Result |
| --- | --- |
| `GET /api/config` | Saved port/IP preferences, MAC allocation, username and storage/capability status; no credential secrets |
| `POST /api/config` | Save a complete port/IP form; see [configuration](configuration.md) |
| `GET /api/ports` | JSON `admin`, `physical`, `forwarding` masks; bits 0–4 map to the five physical ports |
| `POST /api/ports` | Form body `mask=0` through `mask=31`, optionally with both `adv0=4` and `adv1=1..7`; saves to microSD and responds with effective administrative and current physical/forwarding state |
| `GET /api/statistics` | JSON port arrays, optional DDR/debug arrays, health, timeout locations, and sensors |

POST requires `Content-Length` and `X-KR260-Request: 1`, as sent by the supplied
page. This custom header, with no cross-origin permission, prevents ordinary
cross-origin browser forms from changing settings; administrator HTTP Basic authentication is required separately.
Legacy port-only changes do not alter IP configuration. If the last forwarding link goes
down, the existing network link hook can take the network stack down.
HTTP is unencrypted. Responses disable caching and embedding in frames.

The server task has priority 1, a bounded two-entry listen backlog, one active
client, 2 KiB request storage, 24 KiB JSON storage, and a 4096-word stack.
Headers/bodies may arrive in fragments. It rejects ambiguous lengths,
chunked requests, pipelining, oversized requests and invalid masks. Socket
operations have 250 ms waits, request handling has a two-second ceiling,
response sending has a fresh five-second ceiling, and shutdown a two-second drain ceiling.
USB operations have bounded polling/retry loops; USB recovery can extend total
request time. The configuration page allows 20 seconds for a save response.
It closes each connection after its response. This is a small lab-management
server, not a high-concurrency service.

## Build and validation

`make -C software/r5 STATS_DDR=1 STATS_DEBUG=1` builds the firmware with all
counter groups. `web/embed.py` embeds `web/index.html` into the generated
`out/web_page.h`; no separate filesystem is needed on the board. No FPGA
change is required. Use firmware counter options matching the FPGA image.

`make -C software/r5 test` includes HTTP fragmentation, malformed framing,
port-mask validation, missing change-request header, maximum-width counters,
JSON overflow handling, and all four optional-counter combinations. The HTTP
host tests use address/undefined-behavior sanitizers. Browser checks cover
navigation, one-second refresh cadence, exact 64-bit totals, port form posting,
and desktop/mobile rendering. Generated validation artifacts are under
`build/r5/web_validation/`.


## Manual MAC-table snapshots

The public page and refresh operation require no login; they do not change
configuration. `POST /api/mac-table`, with `X-KR260-Request: 1` and body
`refresh=1`, explicitly starts one dump and returns 202 while pending. An
already pending dump is reused. `GET /api/mac-table` returns status/count/
generation/age; `GET /api/mac-table/0` through `/15` returns valid records from
128-slot pages. GET requests never start DMA.

Rows are `[index, "mac", port_mask, age_seconds, ipv4_observations]`.
Each IPv4 observation is `["address", age_ms]`; `null` age means an ARP-cache
fallback without a known observation time, and an empty array means unknown. The browser checks that all
pages share the same generation, preventing mixed snapshots if another user
refreshes. It polls only a manually requested operation, for up to ten seconds,
then stops and permits another manual check. A pending transfer retains DMA
ownership even if the browser leaves or times out.

A dedicated HTTP mutex serializes the dump API across workers. A 32 KiB aligned
DMA staging buffer and a separate 32 KiB published snapshot prevent readers from
accessing memory hardware owns. Completion invalidates the staging cache before
publishing. Errors retain the last complete snapshot. The normal 24 KiB HTTP
response buffers suffice even when all 2,048 MAC slots are occupied, because
each JSON response contains at most 128 records.

For an explicit command-line refresh/inspection:
```sh
python3 scripts/check_mac_table.py 10.0.1.104 --source 10.0.1.24 --refresh
```
Omit `--refresh` to read only the cached snapshot.
See [hardware burst and ownership details](mac-table-dump.md).

## Statistics bank availability

The statistics page now includes each bank's state, last complete collection
age, clock-unavailable episodes and active-clock timeout attempts. Totals remain
visible when stale; a stopped port clock no longer prevents other banks from
refreshing. `/api/statistics` adds `banks`, 13 rows of
`[state, age_ms, clock_unavailable_events, active_clock_timeouts, hardware_status]`.
The page retains its one-second refresh and public read access. State encodings
are documented in [statistics.md](statistics.md). This requires matching ABI-2
hardware/firmware; both were deployed on 2026-09-26. Live browser testing
passes with 13 bank rows, advancing collection, one-second refresh and no
JavaScript errors, including while GEM1 RX has no clock progress.

## Passive IPv4 discovery (2026-09-27, deployed)

The MAC-table page adds IPv4 addresses and Last observed columns. Up to four
addresses per MAC are kept in a 128-mapping R5 observation table. Valid untagged
Ethernet/IPv4 ARP requests and replies reaching the CPU update sender mappings
before the IP stack's destination filtering. A mapping expires ten minutes after
its last observed packet. Repeated packets refresh its timestamp; an IP observed
on a different MAC replaces the old association. Capacity pressure evicts the
oldest observation. These mappings are volatile and independent of the FPGA's
MAC-table aging and dump generation.

When no passive observation exists for a MAC, the firmware tries the FreeRTOS
ARP cache without transmitting or extending its lifetime. This fallback returns
one address and displays `Unknown (ARP cache)` for its observation time.
Otherwise the page displays `Unknown`. Unknown does not establish that a device
has no IP address. Multiple observed addresses and their ages appear in matching
order. IP ages are evaluated when each API page is read; they do not count down
in the browser. Reloading the page reads cached MAC records and current IP
observations without starting a hardware dump or network scan.

This is best-effort discovery of packets already delivered to the CPU; it does
not mirror transit traffic, scan subnets, query DHCP leases, or discover IPv6.
Tagged ARP is ignored because the current table has no VLAN key. Sender Ethernet
and ARP MAC addresses must match, with a nonzero unicast MAC and a usable unicast
IPv4 sender address. Observations are network claims, not authenticated identity.
No FPGA changes or bitstream rebuild are required.
