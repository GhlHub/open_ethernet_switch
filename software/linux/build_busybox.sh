#!/bin/bash
# Build a static development userspace. Source is pinned and checksum-verified.
set -euo pipefail
linux_work=${1:-/tmp/kr260-linux-boot}
linux_cross=${CROSS_COMPILE:-/tools/Xilinx/2026.1/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-}
mkdir -p "$linux_work"
linux_archive="$linux_work/busybox-1.37.0.tar.bz2"
if [[ ! -f "$linux_archive" ]]; then
    curl --fail --location --retry 3 https://busybox.net/downloads/busybox-1.37.0.tar.bz2 -o "$linux_archive"
fi
echo "3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4  $linux_archive" | sha256sum -c -
if [[ ! -d "$linux_work/busybox-1.37.0" ]]; then
    tar -xf "$linux_archive" -C "$linux_work"
fi
linux_source="$linux_work/busybox-1.37.0"
make -C "$linux_source" defconfig
python3 - "$linux_source/.config" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text().replace('# CONFIG_STATIC is not set', 'CONFIG_STATIC=y')
for option in ('TC', 'SHA1_HWACCEL', 'SHA256_HWACCEL'):
    s = s.replace(f'CONFIG_{option}=y', f'# CONFIG_{option} is not set')
p.write_text(s)
PY
# AMD's gcc wrapper injects --gc-sections, which breaks BusyBox's relocatable
# intermediate links. Override it; static glibc also requires retaining sections.
make -C "$linux_source" -j"${JOBS:-16}" CROSS_COMPILE="$linux_cross" \
    CC="${linux_cross}gcc -Wl,--no-gc-sections"
echo "Static BusyBox: $linux_source/busybox"
