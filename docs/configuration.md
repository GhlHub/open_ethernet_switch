# Persistent board configuration

The R5 configuration record reserves five permanent MAC addresses for this board:

| Use | Address |
| --- | --- |
| CPU management interface and STP bridge identity | `00:0a:35:0f:37:45` |
| Reserved | `00:0a:35:0f:37:46` |
| Reserved | `00:0a:35:0f:37:47` |
| Reserved | `00:0a:35:0f:37:48` |
| Reserved | `00:0a:35:0f:37:49` |

Only the first address is used. Physical switch ports do not consume addresses
from this pool merely to forward traffic. Firmware embeds this board's allocation
and rejects records that change it. Other boards need their own allocation.
The CPU MAC change may cause DHCP to issue a different lease than `10.0.1.214`.

## Settings and supported operation

Factory defaults: all ports enabled, GEM0 advertising 1000FD, the other copper
ports requesting 10/100/1000FD, SFP Auto, DHCP, and administrator `admin` /
password `admin`. All copper settings are full duplex only.

| Setting | Stored values | Current running hardware |
| --- | --- | --- |
| GEM0 | 1000 only | 1000 only, PS SGMII limitation |
| GEM1 | Any nonempty subset of 10/100/1000 | Selected advertisement applied by link task |
| PL0, PL1 | Any nonempty subset of 10/100/1000 | 1000 only; 10/100 implementation remains pending |
| SFP | Auto, 1G, 2.5G, 5G, 10G | Auto and 1G run the existing 1G PCS; other rates remain pending |
| IPv4 mode | DHCP or static | Read at network startup |
| Static IPv4 | Address, netmask, default gateway | Read at network startup; DHCP retry disabled in static mode |

A port requesting **only unsupported speeds is de-admitted**: a saved preference
is not evidence of active speed support. PL ports requesting 1000 alongside
10/100 currently run only at 1000; the PL PHY advertisement itself is unchanged.
The SFP higher-rate choices reserve configuration values; they do not add a
multirate PCS, transceiver reconfiguration, or module compatibility guarantees.
`GET /api/ports` reports effective admission and physical speed;
`GET /api/config` reports saved preferences and current implementation capability.

Static settings require a unicast IPv4 host, contiguous /1 through /30 netmask,
and either `0.0.0.0` (no default route) or another host in the same subnet as
the gateway. /31 and /32 management subnets are not supported in this version.
DHCP remains the factory default, with the existing one-minute retry policy.
Port changes apply after successful save; IP changes require firmware restart.
There is no automatic reboot or IP change that interrupts the save response.

## microSD storage and ownership

The KR260 microSD slot is a USB2244 card reader behind the USB0 USB5744 hub,
not a PS SDHCI slot. The R5 owns USB0 through a polled xHCI host driver,
USB hub and SCSI Bulk-Only Transport support, and FatFs. No A53 or Linux
service is required. The USB sources are a pinned BSD-licensed libpayload
subset; see [USB storage](usb-storage.md) for integration and validation limits.
No QSPI region is reserved or written by this configuration implementation.

Use an existing FAT12/16/32 volume (FAT32 recommended); exFAT is unsupported.
Firmware does not partition or format cards. Two root files, `KR260A.CFG` and
`KR260B.CFG`, hold alternating 256-byte records. Unrelated files are preserved.
Startup only reads. No card, missing records, or no valid record means embedded
defaults. Saves require present, mounted media and explicit administrator action.
A present card with no configuration files can receive its first save.
Unknown versions, foreign headers, oversized files or I/O errors disable saving.

Each save re-probes and remounts the card, including unchanged saves. The inactive
file is truncated, written, flushed, closed and read back; its commit marker is
written last and verified. The other file remains intact. Unchanged settings
avoid writes. Failed saves do not publish new settings. The running configuration
stays active after card removal; the next startup without a card uses defaults.
Reload status recognizes a newly inserted card without applying its settings.

Redundant records detect interrupted record writes, but FAT metadata and a card's
internal flash translation layer can still be damaged by power loss. They do not
provide an absolute power-failure guarantee. Remove power only after saving has
completed. CRC detects accidental corruption, not deliberate card tampering.

### Version 1 record (256 bytes, explicit little-endian integers)

| Offset | Bytes | Content |
| --- | --- | --- |
| 0 | 8 | `KR260CFG` magic |
| 8 | 4 | Version 1 |
| 12 | 4 | Generation, wrap-aware comparison |
| 16 | 30 | Five MACs, six bytes each |
| 46 | 32 | NUL-terminated administrator username |
| 78 | 16 | Password salt |
| 94 | 32 | PBKDF2-HMAC-SHA256 password verifier |
| 126 | 4 | PBKDF2 rounds: 100000 |
| 130 | 1 | Five physical-port enable bits |
| 131 | 4 | Copper advertisement masks; bit 0/1/2 = 10/100/1000FD |
| 135 | 2 | SFP Mb/s; zero = Auto |
| 137 | 1 | DHCP boolean |
| 138, 142, 146 | 4 each | IPv4 address, netmask, gateway, network-order octets |
| 150 | 98 | Reserved zero bytes |
| 248 | 4 | CRC-32/ISO-HDLC over bytes 0–247 |
| 252 | 4 | `DONE` commit marker, written last |

## Web/API and host helper

`/configuration` displays the MAC allocation, port preferences, IPv4 fields and
storage state. POST `/api/config` saves a full port/IP update with form fields:
`mask`, `adv0`, `adv1`, `adv2`, `adv3`, `sfp`, `dhcp`, `ip`, `netmask`, `gateway`.
`Content-Length` and `X-KR260-Request: 1` are required. Credential changes
add all three fields `username`, `salt` (32 hex digits), `hash` (64 hex digits).
Omitting this group preserves credentials. Usernames are 1–31 ASCII letters,
digits, underscores, periods or hyphens. Save failures return HTTP 503.
The legacy POST `/api/ports` also saves through the same configuration store.

Viewing pages, statistics and configuration remains public. **Every configuration
POST requires HTTP Basic authentication**, including the legacy `/api/ports` API.
Factory credentials are `admin` / `admin`. Failed authentication returns 401
before any write, with a one-second retry delay. Passwords are verified using
PBKDF2-HMAC-SHA256 with 100000 iterations; the record holds a salt and verifier.
GET responses never return the password, salt or verifier. The helper prompts
for the current password and uses a fresh OS-random salt for replacements.
HTTP Basic credentials travel unencrypted; TLS is not implemented.

```sh
# Read settings, without secrets.
python3 scripts/configure_switch.py --host 10.0.1.214
# Save the current defaults/settings.
python3 scripts/configure_switch.py --host 10.0.1.214 --save
# Prompt twice for the new password, derive its verifier locally and save.
python3 scripts/configure_switch.py --host 10.0.1.214 --username admin --password
# Save static IPv4 for the next firmware startup.
python3 scripts/configure_switch.py --host 10.0.1.214 --dhcp off \
  --ip 10.0.1.215 --netmask 255.255.255.0 --gateway 10.0.1.1
```

If saved settings remove management access, build with `CONFIG_RECOVERY=1`
and load that ELF through the existing JTAG procedure. It bypasses saved values,
uses the factory MAC/DHCP/port settings, and does not write the card on startup.
An explicit save replaces settings with a new generation. Return to a normal
`CONFIG_RECOVERY=0` build afterward. This does not bypass file ownership guards;
foreign or malformed files may require deliberate external recovery. Removing
the card also provides a default-configuration boot.

## Validation status

The all-counter ARM R5 build and host tests pass. Tests cover corrupted records,
interrupted writes, sequence wrap, foreign-file protection, unchanged saves,
port/IP validation, authentication and credential changes. Real FatFs runs over
a disposable RAM disk to test mount, save/reload, absent/replaced cards, failed
writes/flushes, bounds and unrelated-file preservation. USB tests cover aligned
DMA allocation/reuse and SCSI read/write/flush failure handling. Browser tests
exercise public viewing, authenticated saves, MAC/IP/port settings and storage
availability. See `make -C software/r5 test`.

Board verification on 2026-09-24 passed USB enumeration, FAT mounting,
authenticated save/readback and saved-setting reload through two full PS resets.
All ports are enabled in the final saved configuration; DHCP assigned
`10.0.1.104`. The USB2244 requires the guarded write-through compatibility path
described in [USB storage](usb-storage.md). Physical power-cycle, card-removal
and replacement tests remain pending. A transient Ethernet-bound ping outage
recovered without a reset and remains unexplained; see the board-verification
notes rather than treating these checks as a sustained-network reliability test.
