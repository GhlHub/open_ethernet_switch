# Minimal A53 Linux alongside the R5 switch

This is a **volatile JTAG development boot**, with an uncompressed arm64 kernel,
static BusyBox initramfs and a serial root shell. The RAM filesystem is disposable.
QSPI, microSD configuration, and the existing FPGA design are not changed.

Linux owns the four A53 cores, their GIC/timer, and UART1. R5-0 continues to own
switch management, GEM0/GEM1, the PL CPU DMA and MACs, USB0 storage, I2C1/sensors,
and TTC0/TTC1. R5-1 stays reset. Build R5 with `LINUX_CONSOLE=1` to relinquish
UART1: its wrapped output still goes to `board_log`, and its web interface remains
available. The default `LINUX_CONSOLE=0` keeps the existing standalone behaviour.

The deliberately small device tree omits R5-owned peripherals and Linux PS power
management. Clocks are established by the design's FSBL and left running. This
is a first-boot ownership contract, not a complete Linux board-support package.
It does not provide a Linux network interface, persistent storage, remoteproc,
RPMsg, telemetry DMA, CPU frequency scaling, or suspend. Adding those requires
an explicit ownership/power-management review; do not substitute a stock KR260
device tree because it would claim peripherals already used by R5.

## Memory and boot chain

Linux initially uses only the low 2 GiB of DDR. Both existing reservations are
marked `no-map`: the 512 KiB PL packet pool at `0x10000000`, and all 32 MiB of R5
DDR at `0x20000000` (including USB and Ethernet DMA regions).

| Payload | Load address | Lifetime |
| --- | --- | --- |
| Linux `Image` | `0x00200000` | Kernel; runtime extent checked against DTB |
| Device tree | `0x04000000` | Linux boot data |
| Compressed initramfs | `0x06000000` | Linux unpacks into RAM |
| BL33 entry shim | Entry `0x08000000` | Temporary; ELF LOAD includes header page below entry |
| TF-A BL31 | OCM, entry `0xFFFEA000` in tested build | Secure monitor/PSCI |
| R5 ELF | R5 local ATCM and reserved DDR | Existing application |

Boot order: system reset with temporary JTAG boot-mode override, PMU firmware,
the **current switch XSA's FSBL**, existing switch bitstream, halted R5 ELF,
Linux payloads, then TF-A. TF-A enters a tiny BL33 shim at EL2; it passes the DTB
and branches to Linux following the [arm64 boot protocol](https://docs.kernel.org/arch/arm64/booting.html).
R5 starts 15 seconds later. That delay is sequencing, not proof of Linux readiness;
the UART readiness marker and hardware checks below establish success. No U-Boot
is needed for this RAM-only experiment. The boot-mode override is restored on exit.

## Build and stage

Prerequisites: Vitis 2026.1 cross tools and XSDB, Python 3, `dtc`, host C compiler,
GNU make, curl, tar, and the existing R5 BSP/FSBL plus routed switch bitstream.

```sh
bash software/linux/build_busybox.sh /tmp/kr260-linux-boot
make -C software/r5 -j16 LINUX_CONSOLE=1 STATS_DDR=1 STATS_DEBUG=1
python3 software/linux/prepare.py \
  --kernel /path/to/Image \
  --atf /path/to/bl31.elf \
  --pmufw /path/to/pmufw.elf \
  --busybox /tmp/kr260-linux-boot/busybox-1.37.0/busybox \
  --r5 software/r5/out/kr260_r5.elf
python3 software/linux/verify.py
```

The statistics flags above match the current dual-rate FPGA image; always match
them to the chosen bitstream's capabilities. A mismatch disables statistics.

`prepare.py` takes external kernel/firmware explicitly and writes hashes and input
paths to `build/linux/manifest.json`. It requires a little-endian arm64 `Image`
with zero text offset, static BusyBox, and the Linux-console R5 ELF marker.
The preboot verifier checks hashes, memory reservations and payload placement.
BusyBox 1.37.0 is downloaded from its official site and SHA-256 checked before
building; the build script includes the AMD compiler-wrapper workaround.

The initial components come from locally built AMD EDF 2026.1 artifacts:

- Linux 6.18.10, `Xilinx/linux-xlnx` revision
  `4f7afe14f7246986ca858d9a0880f5db6ba02a4b`.
- TF-A 2.14.0, `Xilinx/arm-trusted-firmware` revision
  `501fae71936c40f59b493b76fb41f4d0fbb1b139`, built with
  `PLAT=zynqmp ZYNQMP_CONSOLE=cadence1 PRELOADED_BL33_BASE=0x08000000`.
- PMU firmware from `Xilinx/embeddedsw` revision
  `2177ef5d0e8bc6049d59034377c3c9afc9dbb21a`, with PM support enabled.

Their local deploy root is `/tmp/kv260-yocto-2026.1/tmp/deploy/images/`:
`amd-cortexa53-mali-common/Image`, and `k26-smk-kv-sdt/arm-trusted-firmware.elf`
plus `k26-smk-kv-sdt/pmu-firmware-k26-smk-kv-sdt.elf`. Only these components are
reused; the KV260 FSBL, board device tree and U-Boot are **not** used. The kernel
is an existing general AMD kernel; the userspace and exposed hardware are minimal.
Rebuilding that kernel/firmware uses their pinned EDF recipes, not this script.

## Boot and verify

Connect the UART bridge with `telnet 10.0.1.109 2323`, then run:

```sh
/tools/Xilinx/2026.1/Vitis/bin/xsdb software/linux/boot_jtag.tcl \
  tcp:10.0.1.109:3121 \
  build/ip_refactor/sfpdual_release3/project/kr260_switch.runs/impl_dual_timing2/kr260_top.bit
```

This replaces the running volatile session. Expect several minutes for JTAG
transfers. Success requires `KR260_MINIMAL_LINUX_READY` on UART, followed by:

```sh
uname -a
cat /sys/devices/system/cpu/online
cat /proc/meminfo
cat /proc/iomem
cat /proc/interrupts
```

Check four CPUs (`0-3`), both reserved memory ranges, shell input/interrupts,
and the R5 webpage/statistics while Linux runs. Test endpoint forwarding under
A53 memory/CPU activity. A boot message alone is not a coexistence test.
The console is an unauthenticated development root shell, not a deployed service.
Press Enter for the `~ #` prompt. To disconnect from the command-line Telnet
client, press Ctrl+] and enter `quit`. Linux has no SSH or network interface in
this image; `10.0.1.104` remains the R5 management address.

### Telnet inserts `?` before the next command

An older UART Telnet bridge forwards Telnet's `CR NUL` directly to the UART.
BusyBox then shows `~ # ?`, and the next command fails as `?command: not found`.
This was reproduced on the running board; it is a bridge input-decoding issue.

The fixed bridge has now been restarted on the Windows host, and the user
confirmed that the Linux console works correctly. No client workaround is needed
with the updated bridge.

For older bridge deployments, a workaround with the command-line Telnet client is
to press
**Ctrl+]**, enter `toggle crlf`, then press **Ctrl+C** at the Linux console to
clear the corrupted input. Subsequent commands work, though the old bridge may
show an extra blank prompt. Toggle only when needed: the client should report
`Will send carriage returns as telnet <CR><LF>`.

The permanent fix is in the separate `uart_telnet_bridge` project: retain
Telnet parsing state across TCP receives and convert both `CR NUL` and `CR LF`
to one UART CR. Updating/restarting that bridge does not require a Linux or
FPGA rebuild. The fix passed all ten bridge tests on 2026-09-28; deployment
to the bridge host is separate from the KR260 boot image.

## Hardware qualification — 2026-09-28

The final JTAG boot completed on the KR260 with Linux 6.18.10 and all four A53
cores online. `/proc/iomem` confirmed both `no-map` reservations. The serial
shell worked, and the interrupt report showed activity on all four CPUs with
`Err: 0`. Linux reported 1,946 MiB usable memory from the initial low-DDR bank.

While four CPU-pinned processes each hashed the same 128 MiB RAM file five
times, all **20 hashes matched** the host-computed value. All **16 concurrent
R5 statistics requests succeeded**; the statistics poll count advanced from
28 to 98 with zero read/release/response timeouts. Sensors remained valid with
zero reported errors. R5 configuration reported its saved settings present
and storage writable; no configuration write was performed.

| Full-size ICMP check | Result |
| --- | --- |
| R5 management `10.0.1.104`, during A53 load | 200/200 replies |
| SFP endpoint `10.0.1.135`, during A53 load | 200/200 replies |
| PL1 endpoint `10.0.1.140`, during A53 load | 199/200 replies |
| PL1 endpoint, subsequent idle-A53 control | 497/500 replies |

PL1's intermittent packet loss remains unresolved. Loss also occurred with
Linux idle; these short tests do not establish its cause or qualify line-rate
forwarding. The SFP host interface reported 10G; this does not measure the
copper module's cable-side negotiated rate.

Both R5 console variants built, the existing R5 regression suite passed, and
the boot checker rejected a standalone-console ELF, a changed kernel hash,
and a shortened R5 reservation. An initial boot exposed a statistics build-flag
mismatch and incorrect early-console baud programming; both were corrected
before the final boot and tests above.

Local evidence is under `build/linux/`: `boot-final.log`, `uart-final.log`,
`linux-final-check.log`, `live-results.json`, `stats-final-{before,after}.json`,
`http-during-load.json`, ping logs, and the artifact manifest. Final tested hashes:

| Artifact | SHA-256 |
| --- | --- |
| `Image` | `4e5ae9e5fb8f1f3317636ce2788af06ff91af514848a80527a7facaebefd3ddc` |
| `r5-linux.elf` | `97fd5b350fc455b3ab70fcf9b22c4e08aeacbcf6a3bdd6ff1c600869d095be28` |
| `system.dtb` | `593176acb5ca220a6c547e2dede07ef361a8215821ddfbda4c599effc7eab8a2` |
| `rootfs.cpio.gz` | `daf7a39d96a61e7739482bbe0d899c12ce2386961515b569e84a2315c59f7154` |

## Return to standalone R5

```sh
make -C software/r5 -j16 LINUX_CONSOLE=0 STATS_DDR=1 STATS_DEBUG=1
/tools/Xilinx/2026.1/Vitis/bin/xsdb software/r5/boot_jtag.tcl \
  tcp:10.0.1.109:3121 \
  build/ip_refactor/sfpdual_release3/project/kr260_switch.runs/impl_dual_timing2/kr260_top.bit
```

This resets the A53/Linux session and restores the R5 serial console without
writing persistent media.
