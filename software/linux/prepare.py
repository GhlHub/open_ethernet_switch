#!/usr/bin/env python3
"""Stage audited external boot components and build the RAM-only JTAG payload.

Inputs must be matching ZynqMP firmware: TF-A BL33=0x08000000, UART1 console,
PMUFW with power management, and a kernel with initramfs/UART/PSCI support.
Hashes and input paths are recorded, never silently fetched from other projects.
"""
import argparse
import gzip
import hashlib
import json
import re
from pathlib import Path
import shutil
import stat
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SRC = Path(__file__).resolve().parent


def archive(entries):
    """Deterministic newc, including console device without requiring root."""
    result = bytearray()
    for ino, (name, mode, data, major, minor) in enumerate(entries + [
            ('TRAILER!!!', 0, b'', 0, 0)], 1):
        name = name.encode() + b'\0'
        fields = (ino, mode, 0, 0, 1, 0, len(data), 0, 0, major, minor, len(name), 0)
        result.extend(b'070701' + ''.join(f'{x:08x}' for x in fields).encode())
        result.extend(name)
        result.extend(b'\0' * (-len(result) % 4))
        result.extend(data)
        result.extend(b'\0' * (-len(result) % 4))
    return bytes(result)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('kernel', 'atf', 'pmufw', 'busybox', 'r5'):
        p.add_argument('--' + name, required=True, type=Path)
    p.add_argument('--cross', default='/tools/Xilinx/2026.1/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-')
    p.add_argument('--dtc', default='dtc')
    p.add_argument('--out', type=Path, default=ROOT / 'build/linux')
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    symbols = subprocess.check_output([args.cross + 'nm', str(args.r5)], text=True)
    if not re.search(r'^0*1 A kr260_linux_console$', symbols, re.M):
        p.error('R5 ELF must be built with LINUX_CONSOLE=1')
    kernel = args.kernel.read_bytes()
    offset, size, flags = struct.unpack_from('<QQQ', kernel, 8)
    if kernel[56:60] != b'ARM\x64' or offset != 0 or flags & 1:
        p.error('Expected little-endian arm64 Image with text_offset=0')
    if not size or max(size, len(kernel)) > 0x04000000 - 0x00200000:
        p.error('Kernel runtime extent overlaps DTB')
    busybox_headers = subprocess.check_output([args.cross + 'readelf', '-l', str(args.busybox)], text=True)
    if 'INTERP' in busybox_headers:
        p.error('BusyBox must be statically linked')
    manifest = {'kernel_runtime_size': size, 'r5_linux_console': True, 'inputs': {}, 'load_addresses': {
        'Image': '0x00200000', 'system.dtb': '0x04000000',
        'rootfs.cpio.gz': '0x06000000', 'entry.elf': '0x08000000'}}
    for key, output in [('kernel', 'Image'), ('atf', 'bl31.elf'), ('pmufw', 'pmufw.elf'), ('r5', 'r5-linux.elf')]:
        source = getattr(args, key).resolve()
        if source != (args.out / output).resolve():
            shutil.copyfile(source, args.out / output)
        manifest['inputs'][output] = {'path': str(source), 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
    entries = [(n, stat.S_IFDIR | 0o755, b'', 0, 0)
               for n in ('bin', 'sbin', 'usr', 'usr/bin', 'usr/sbin', 'dev', 'proc', 'sys', 'run', 'tmp', 'etc')]
    entries += [('dev/console', stat.S_IFCHR | 0o600, b'', 5, 1),
                ('bin/busybox', stat.S_IFREG | 0o755, args.busybox.read_bytes(), 0, 0),
                ('init', stat.S_IFREG | 0o755, (SRC / 'init').read_bytes(), 0, 0)]
    apps = 'sh mount mkdir cat echo uname hostname setsid cttyhack sleep grep awk free ps dmesg ls hexdump dd sha256sum taskset seq yes head wc kill sync printf date top uptime touch rm pwd cp tee'.split()
    entries += [('bin/' + app, stat.S_IFLNK | 0o777, b'busybox', 0, 0) for app in apps]
    rootfs = gzip.compress(archive(entries), mtime=0)
    if len(rootfs) >= 0x02000000:
        p.error('Initramfs overlaps entry shim')
    (args.out / 'rootfs.cpio.gz').write_bytes(rootfs)
    dts = (SRC / 'kr260-minimal.dts').read_text().replace('INITRD_END', hex(0x06000000 + len(rootfs)))
    (args.out / 'system.dts').write_text(dts)
    subprocess.run([args.dtc, '-I', 'dts', '-O', 'dtb', '-o', str(args.out / 'system.dtb'), str(args.out / 'system.dts')], check=True)
    subprocess.run([args.cross + 'gcc', '-nostdlib', '-static', '-no-pie', '-Wl,--build-id=none,-Ttext=0x08000000,-e,_start', str(SRC / 'entry.S'), '-o', str(args.out / 'entry.elf')], check=True)
    manifest['busybox'] = {'path': str(args.busybox.resolve()), 'sha256': hashlib.sha256(args.busybox.read_bytes()).hexdigest()}
    manifest['outputs'] = {name: hashlib.sha256((args.out / name).read_bytes()).hexdigest()
                           for name in ('Image', 'bl31.elf', 'pmufw.elf', 'r5-linux.elf', 'system.dtb', 'rootfs.cpio.gz', 'entry.elf')}
    (args.out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Prepared {args.out}; rootfs {len(rootfs)} bytes, kernel runtime {size} bytes')


if __name__ == '__main__':
    main()
