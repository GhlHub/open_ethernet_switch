# R5 web interface

The R5 serves a self-contained HTTP interface on TCP port 80 at its configured IPv4
address (DHCP by default). Viewing is public and uses no external assets.
Configuration changes require administrator credentials (factory `admin` / `admin`).
The current lab address after the permanent-MAC change is `http://10.0.1.104/`
(2026-09-24 DHCP lease).

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
The page distinguishes future PL/SFP speeds from current implementation;
unsupported-only selections disable admission. IP changes apply after restart.
The five permanent MACs and administrator username are displayed; stored
password verifiers are never returned. See [persistent configuration](configuration.md)
for storage layout, credentials, recovery and current hardware limits.
See [PS speed selection](ps-ethernet-speeds.md) for PS transition behavior.
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
