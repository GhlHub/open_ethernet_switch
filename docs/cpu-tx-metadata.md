# CPU transmit metadata — stream ABI 1

## Contract

Every CPU MM2S transfer contains a two-byte private header followed by one
Ethernet frame. The header is part of the same DMA buffer and descriptor as
the frame. There is no separate arm operation, pending override register,
metadata clock-domain crossing or timing assumption between a CSR write and
DMA submission. There is no legacy raw-frame transmit mode.

| Stream item | Value |
| --- | --- |
| First byte (low lane of first 16-bit beat) | Bit 6: directed frame; bits 4:0: physical destination mask; bits 7 and 5 reserved zero |
| Second byte (high lane) | `0xA5` magic/version marker |
| Remaining bytes | Ethernet destination MAC through payload/padding, without FCS |

Ordinary traffic uses header word `0xA500`; normal MAC lookup/flooding applies.
Directed traffic to PL0 uses `0xA544`, to PL1 `0xA548`. Directed mask zero is
an intentional no-destination frame. CPU source port bit 5 is excluded.
An ordinary header must have mask zero. FCS and physical minimum-frame
handling remain with the Ethernet MACs; firmware pads the Ethernet portion
to at least 60 bytes before adding the header.

`switch_fabric` 1.1 strips the header in the fabric clock domain before MAC
parsing/learning, packet counters, the CPU ingress buffer and DDR storage.
All other physical streams and the fabric-to-CPU RX stream remain Ethernet
frames without this header. Stream framing remains TLAST-delimited.

The framer accepts a header, passes that frame under normal AXIS backpressure,
then blocks the next header until the frame's enqueue request is granted.
Its destination mask is immutable throughout receive, DDR write and enqueue.
Consequently, MM2S descriptor completion can precede enqueue safely: a later
DMA descriptor may be submitted, but its header cannot replace the preceding
frame's metadata. This preserves the existing one-frame-at-a-time CPU ingress
architecture without adding another metadata queue.

Malformed headers (wrong magic, reserved bits, partial TKEEP, ordinary mask)
are drained through TLAST without forwarding payload. Header-only transfers
are discarded. These rejected transfers do not count as good Ethernet frames;
there is no new malformed-header diagnostic counter in this change. Ethernet
payload validation/error handling otherwise follows the existing CPU ingress
implementation; the trusted firmware sender enforces its length limits.

## Firmware and register interface

Management 1.2 exposes `CPU_TX_ABI` at diagnostics offset `0x54`, value
`0x43545801`. The old `0x4C` arm register is retired (writes ignored, reads
zero), and its scalar ports and CDC instance are removed from production.
New firmware checks `CPU_TX_ABI` before initializing DMA and fails closed on
a mismatched image. This check catches lab image mixups; it provides no
backward-compatible data path. Deploy matching hardware and firmware together.

`fabric_dma_send()` creates an ordinary header.
`fabric_dma_send_directed()` creates a directed header; `pstate_cpu_tx_raw()`
uses it directly without a preceding MMIO write. Both call one serialized
sender that holds the TX mutex while preparing header/payload/descriptor,
submitting DMA and waiting for completion. It rechecks DMA health after
acquiring the mutex, in case the previous sender failed while it waited.
Invalid arguments have no pending hardware metadata side effects.

Descriptor lengths include the two private bytes. Ethernet lengths, switch
DDR lengths and normal packet/byte counters exclude them. A maximum supported
1,514-byte Ethernet frame therefore uses a 1,516-byte DMA transfer, within the
existing 1,536-byte bounce buffer. DMA memory/cache ownership is unchanged.

## Reset and failure contract

Resetting the framer clears its metadata and parser state. A fabric reset
must also quiesce/reset the upstream MM2S producer and discard outstanding
transfers; resuming a partially transmitted DMA frame after a parser reset is
unsupported. After DMA timeout/error, firmware retains its existing fail-closed
policy and refuses later sends. There is no independent override to cancel.
Automatic DMA restart, fabric DDR-error recovery and the separate CPU RX-tag
alignment concerns are not implemented by this change.

This removes the CPU override CDC and arming race. It does not close the
remaining STP task-ownership, protocol, RX-tag and physical CDC review items;
STP remains disabled by default.

## Verification and deployment

The focused framer bench checks alternating ordinary/directed metadata,
byte/TKEEP/TLAST preservation, randomized downstream readiness, delayed enqueue,
back-to-back transfers, malformed headers and reset in BODY/WAIT_DONE.
The whole-switch test verifies directed enqueue to one port followed by normal
lookup/flooding. Host DMA tests verify private headers, padding, descriptor
rotation, mixed concurrent senders, invalid lengths, incompatible hardware,
and timeout/error behavior. Firmware builds retain ELF/DMA memory audits.

The CPU TX ABI intentionally changes behavior. Historical pre-partition
cycle equivalence is no longer an appropriate acceptance claim. Native
regressions run all four counter configurations; the packaged production
assembly is compared with the **current** native assembly. Focused scoreboards
check leaf functionality independently of that shared-leaf assembly miter.

Simulation artifacts are under `build/ip_refactor/cpu_tx_metadata_acceptance/`
and `build/ip_refactor/cpu_tx_*`. The combined metadata/pipelined-CPU-DMA
revision was subsequently rebuilt, routed and deployed with matching firmware.
See [board validation](verification.md#2026-09-26-cpu-tx-metadata-and-dma-pipeline-board-deployment)
and `build/ip_refactor/cpu_tx_pipeline_impl/` for the current evidence.
