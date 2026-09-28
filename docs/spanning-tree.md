# Classic STP and Rapid Spanning Tree

The 2026-09-27 source supports classic STP (protocol version 0) and RSTP
(version 2), using the pinned Apache-2.0 [mstp-lib](https://github.com/adigostin/mstp-lib)
engine. This replaces the earlier partial classic-STP implementation. One common
spanning tree covers the five physical ports; the CPU port is not a tree port.
MSTP/VLAN instances are not exposed. This update was deployed on 2026-09-27
with STP disabled. Protocol board qualification is deferred at the user’s request.

## Configuration

On Configuration, select **Enable spanning tree** and choose **Classic STP** or
**Rapid STP**. Save using administrator credentials and an inserted writable
FAT microSD card. Viewing configuration and statistics remains public. Settings
apply after a successful save; changing protocol while enabled restarts tree
convergence. Disabling restores ordinary learning/forwarding, still subject to
administrative enable and physical link admission. Redundant physical links can
form a loop when spanning tree is disabled.

Defaults are disabled, with RSTP selected. Version-1 SD records migrate to these
values without changing existing port/IP/credential settings. New writes use
record version 2 (STP enable at byte 150, protocol version at byte 151). Missing
card/configuration still selects factory defaults; saves without media fail.
Older firmware cannot read v2 records; retain a card backup before downgrading.

`GET /api/config` includes `stp` (boolean) and `stp_version` (0 or 2).
POST adds `stp=0|1&stp_version=0|2`; both must be present together. Older clients
that omit both retain the current spanning-tree settings. `/api/statistics`
reports enabled state, selected version, root identity/cost, per-port role/state,
BPDU counters, topology changes, rejected/dropped RX BPDUs, TX failures, and a
hardware-fault indication. Port configuration's “Link admitted” column refers
to link admission; the statistics spanning-tree table reports protocol state.

The bridge identity remains `00:0a:35:0f:37:45`, priority 32768, for either
protocol. Full-duplex links are point-to-point; automatic/admin edge forwarding
is disabled. An endpoint that sends no BPDUs can therefore wait for timer-based
forwarding. RSTP proposal/agreement provides rapid transitions between compatible
bridges. Protocol migration handles classic neighbors. Long path costs are
computed from negotiated speed (20,000 at 1 Gb/s, 200,000 at 100 Mb/s,
2,000,000 at 10 Mb/s). Speed changes restart that port's protocol state.

## Task and hardware contracts

Only `stp_task.c` enters the protocol engine. The network task copies received
BPDUs and their ingress tags into a bounded 32-frame queue. The owner polls
configuration/links every 10 ms, services one-second protocol timers, and drains
at most 16 queued frames per iteration. RX older than one second is discarded;
queue overflow, invalid/missing ingress tags and rejected frames are counted.
Web tasks read an atomically published snapshot. The task clears forwarding
before reinitializing a tree; startup applies the saved enable gate before
physical links are admitted.

Fabric 2.1 adds two prerequisites:

- Ordinary traffic's destination mask excludes non-forwarding ports, including
  normal CPU traffic. Explicit CPU-directed control frames bypass that mask so
  BPDUs can transmit through a discarding port. Reserved control RX still reaches
  the CPU even when its ingress port is discarding.
- CPU dequeues stop when the ingress-tag FIFO is full. Packet-stream buffering
  can hold more frames than the R5 descriptor ring, so matching FIFO depth to
  ring depth alone was insufficient. Exactly one tag remains associated with
  each retired RX descriptor, including malformed packets.

Management 2.1 exposes `STP_ABI` at `0x80100058`, value `0x53545002`. Firmware
rejects a save enabling STP on older hardware. Booting an enabled saved record
on incompatible hardware keeps forwarding blocked and reports a fault. A new
bitstream is required to use this feature; statistics ABI remains version 2.

All flush-generating link/forward/learn writes use a shared RTOS mutex, allow
clock-domain propagation, and wait for flush completion. This prevents toggle
cancellation between tasks or consecutive forwarding/learning clears. A flush
that remains busy for 100 ms latches a fault and prevents reopening forwarding
until restart. The topology-change callback performs an immediate per-port MAC
and queue flush, briefly blocking forwarding and restoring the protocol's
intended state after completion. Classic-STP rapid-aging requests also receive
this conservative immediate flush rather than a programmable aging interval.
This can discard queued packets and increase flooding during topology changes.

## Verification and deployment status

Host protocol tests use packet delivery between three independent instances of
the same engine. They check RSTP triangle convergence within three simulated
seconds, absence of forwarding loops during transitions, link failure/recovery,
FDB flush callbacks, malformed-frame rejection, classic STP and mixed neighbors.
Task tests cover queued BPDU ownership/drop reporting, runtime enable/disable,
version changes, timer service and fail-closed hardware-version handling.
Configuration/browser tests cover both choices, persistence, old-record migration
and existing authorization/storage behavior.

RTL regressions cover blocked ingress, blocked egress with directed-control
bypass, and full-tag-FIFO backpressure/recovery. These tests do not constitute
independent vendor interoperability certification. The new bitstream and R5
firmware are deployed and basic DHCP, forwarding, web/SNMP and sensor functions
have been checked. STP remains disabled; live loop, cable-flap, topology-change
and mixed-neighbor qualification is deferred. See the deployment entry in
[verification.md](verification.md).
