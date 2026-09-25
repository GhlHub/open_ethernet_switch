# Startup and HTTP investigation — 2026-09-25

## DHCP startup

The R5 interface follows whether **any admitted physical fabric port** is up.
It does not know which port leads to DHCP. On this board PL0, connected to the
endpoint, is admitted first; GEM1, the uplink, completes initialization later.
Previously this immediately enabled the R5 interface and started DHCP.

Added a nonblocking readiness gate: DHCP mode requires at least one physical
port continuously available for at least 1,000 ms before exposing interface
readiness to FreeRTOS+TCP. The 250 ms link poll evaluates this gate, so release
may occur on a later poll. Losing all physical links cancels it. Static-IP
mode has no added delay. This gate does not delay physical fabric forwarding,
and adding another port while the aggregate link remains up does not restart
an already active interface or discard an acquired lease.

The delay alone did not solve acquisition. Timestamped UART evidence from
that intermediate firmware:

| Event | Time |
| --- | --- |
| First admitted physical link (PL0) | 1,597 ms after scheduler start |
| R5 interface ready | 2,837 ms |
| First DHCP Discover | 3,088 ms |
| GEM1 admission | Approximately 5.3 s, based on UART receive timestamps |
| DHCP gives up | Approximately 8.4 s |

FreeRTOS+TCP starts its Discover retransmission period at 5 seconds. It doubles
that period **before** comparing it with `ipconfigMAXIMUM_DISCOVER_TX_PERIOD`.
Our 8-second ceiling therefore rejected the first retry (10 seconds): there
was just one Discover, transmitted before the uplink was ready. Failure then
correctly invoked our separate one-minute retry policy.

Changed the ceiling to 32 seconds, allowing the 10- and 20-second periods.
With the same board wiring and FPGA image, the final firmware sent Discover
at 3,088 ms and again at 8,338 ms, sent Request at 8,340 ms and acquired
`10.0.1.104` immediately afterward. No initial failure or one-minute retry
occurred on that boot; a second boot of the final firmware reproduced the
same DHCP timing. Failed acquisition cycles still wait 60 seconds from
failure; this is distinct from retransmissions within an acquisition cycle.
UART now logs physical-link, interface-readiness and DHCP transmit times.

## Physical forwarding recovery

Continuous endpoint pings around the intermediate-firmware JTAG reboot showed
a 25.049-second gap, including system reset, FPGA programming and PHY setup.
The first subsequent reply arrived about 0.86 seconds after UART reported
GEM1 admitted. UART arrival timestamps have buffering uncertainty. Some echo
requests queued by the workstation were then returned together.

This supports link/reinitialization timing as a major contributor to the
observed startup loss, rather than dependence on the R5's DHCP lease. It does
not prove the cause of the remaining subsecond post-link interval: neighbor
resolution, peer behavior and local admission/CDC timing have not been
separately measured. A workstation packet capture was unavailable without
sudo credentials; no packet-level DHCP-offer or ARP timing claim is made.
The DHCP fix does not make JTAG reset or physical-link startup lossless.

On the first boot with the larger DHCP ceiling, a simultaneous post-lease
full-MTU test returned 500/500 endpoint replies but only 395/500 R5 replies:
sequence 1 succeeded, sequences 2–106 were absent, and 107–500 succeeded.
A subsequent R5 test passed 200/200. Statistics showed no bad packets, DDR
response errors, or mailbox timeouts. This approximately five-second R5-only
gap remains unresolved; acquiring DHCP earlier is not proof that all startup
packet loss has been fixed.

## HTTP architecture confirmed

`web_task.c` owns one listener and processes accepted sockets serially through
`serve()`. The request and response arrays are global, shared buffers. One
client can occupy the task through receive/send timeouts, response close,
a one-second authentication rejection delay, or a settings save.

For this FreeRTOS+TCP version, `FreeRTOS_listen(listener, 2)` means at most two
**child sockets**, including accepted connections. In
`FreeRTOS_TCP_State_Handling_IPv4.c`, an incoming SYN when `usChildCount >=
usBacklog` triggers `prvTCPSendReset()`.

Controlled board test: open two TCP connections without sending HTTP, then
immediately open a third. In all five trials the first two connected and the
third received `ECONNREFUSED`. Browser tests independently showed
`/api/config` refused while `/api/ports` succeeded. Configuration initializes
with `Promise.all()` for those two API calls; browser preconnections and
connections still closing can consume the same small limit. Isolated polling
passed 55/55 reads on the previous test. This confirms an HTTP connection-
capacity/serialization issue rather than a packaged-IP counter-routing fault.

Recommended follow-up: a dedicated acceptor and a bounded worker pool (or a
nonblocking per-connection state machine), adequately sized listener capacity,
per-client request/response buffers and deadlines, and serialized persistent
configuration writes. Simply adding worker tasks around the current global
buffers is unsafe. Raising the listener limit can reduce refusals but alone
does not remove head-of-line blocking. No HTTP implementation change was made
in this investigation.

## Validation and artifacts

The R5 host test suite passed, including new readiness boundary, link-flap,
static-mode and tick-wrap tests. All-counter firmware build and ELF/DMA memory
audits passed. The final firmware was loaded with the existing management 1.1
bitstream; no FPGA rebuild was needed. See verification.md for the final
ping/counter checks. Final settled R5/endpoint full-MTU checks passed 200/200
each with clean packet/DDR/mailbox counters. Logs are under `build/ip_refactor/startup_investigation/`.
