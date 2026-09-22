# R5 web interface

The R5 serves a self-contained HTTP interface on TCP port 80 at its DHCP
address. No login, browser credentials, external assets, or internet access
are required. Both viewing and changing port configuration are unauthenticated.
The current lab address is `http://10.0.1.214/`.

- `/configuration`: enable/disable GEM0 (right upper), GEM1 (right lower),
  PL0 (left upper), PL1 (left lower), and SFP. Physical link and effective
  forwarding state are displayed separately. Apply submits the five-port mask;
  Reload status fetches the latest settings without applying edits. Link and
  speed cells refresh every second without overwriting checkbox edits.
- `/statistics` (also `/`): refresh accumulated port counters, compiled-in
  DDR/debug counters, collector health, per-bank/slot timeout counts, and
  temperature/voltage/SOM power readings every second. Requests never overlap;
  failed requests mark the displayed information stale and polling continues.

Settings are RAM-only and default to all five ports enabled on every firmware
restart, with GEM0 advertising 1000FD and GEM1 advertising 10/100/1000 full duplex.
The page offers GEM1 advertisement checkboxes; changing them interrupts negotiation.
See [PS speed selection](ps-ethernet-speeds.md) for transition behavior and API. The CPU virtual port is not administratively configurable. Disabling
ports changes MAC receive enables and masks the link task's desired fabric
ports. The existing link-clear/queue flush/MAC-learning flush sequence handles
removal. PHY negotiation remains active, so a disabled port can still report
physical link up. Already accepted/in-flight traffic can finish during the
transition; this is not an instantaneous packet-boundary isolation mechanism.
Changes are applied by the 250 ms link task. Re-enable follows its existing
flush-busy check and interval guard. PS GEM RX/TX are stopped while disabled;
PL/SFP reception is stopped and fabric egress destinations are removed/flushed.

Disabling the management uplink can disconnect the browser before it receives
the response. Recover through another enabled port or reboot the board. There
is no persistent configuration or automatic rollback in this initial version.

Statistics use the same nondestructive `statistics_get` / `sensors_get` snapshots
as SNMP. The processor remains the sole reader of hardware clear-on-read
counters. Counter totals are encoded as decimal strings in JSON, preserving
all 64 bits in JavaScript. DDR/debug fields are omitted when not compiled in;
sensor validity and collector availability are visible. Voltage and current
readings use three decimal places (`1.800 V`, `0.800 A`); temperatures use one
(`30.0 °C`). DDR/debug cycles are
100 MHz fabric cycles (10 ns). CPU RX means CPU to fabric; TX means fabric to CPU.

## HTTP API

| Method/path | Result |
| --- | --- |
| `GET /api/ports` | JSON `admin`, `physical`, `forwarding` masks; bits 0–4 map to the five physical ports |
| `POST /api/ports` | Form body `mask=0` through `mask=31`, optionally with both `adv0=4` and `adv1=1..7`; responds with the requested administrative and current physical/forwarding state |
| `GET /api/statistics` | JSON port arrays, optional DDR/debug arrays, health, timeout locations, and sensors |

POST requires `Content-Length` and `X-KR260-Request: 1`, as sent by the supplied
page. This custom header, with no cross-origin permission, prevents ordinary
cross-origin browser forms from changing settings; it is not authentication.
Port changes do not alter IP configuration. If the last forwarding link goes
down, the existing network link hook can take the network stack down.
HTTP is unencrypted. Responses disable caching and embedding in frames.

The server task has priority 1, a bounded two-entry listen backlog, one active
client, 2 KiB request storage, 24 KiB JSON storage, and a 4096-word stack.
Headers/bodies may arrive in fragments. It rejects ambiguous lengths,
chunked requests, pipelining, oversized requests and invalid masks. Socket
operations have 250 ms waits, request handling has a two-second ceiling,
sending a five-second total ceiling, and shutdown a two-second drain ceiling.
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
