#!/usr/bin/env python3
"""Validate staged hashes, DT ownership/reservations and load extents."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys

def elf_loads(path):
    data = path.read_bytes()
    assert data[:4] == b'\x7fELF' and data[5] == 1, path
    if data[4] == 2:
        entry, offset = struct.unpack_from('<QQ', data, 24)
        stride, count = struct.unpack_from('<HH', data, 54)
        fmt, addr_index, size_index = '<IIQQQQQQ', 4, 6
    else:
        assert data[4] == 1, path
        entry, offset = struct.unpack_from('<II', data, 24)
        stride, count = struct.unpack_from('<HH', data, 42)
        fmt, addr_index, size_index = '<IIIIIIII', 3, 5
    loads = []
    for i in range(count):
        fields = struct.unpack_from(fmt, data, offset + i * stride)
        if fields[0] == 1 and fields[size_index]:
            loads.append((fields[addr_index], fields[addr_index] + fields[size_index]))
    assert loads, path
    return entry, loads

def properties(blob):
    """Read DTB structure tokens; return absolute node paths and raw properties."""
    magic, total, pos, strings = struct.unpack_from('>4I', blob)
    assert magic == 0xd00dfeed and total <= len(blob)
    nodes, stack = {}, []
    while pos < total:
        token, = struct.unpack_from('>I', blob, pos)
        pos += 4
        if token == 1:
            end = blob.index(0, pos)
            stack.append(blob[pos:end].decode())
            pos = (end + 4) & ~3
            nodes['/'.join(stack) or '/'] = {}
        elif token == 2:
            stack.pop()
        elif token == 3:
            size, nameoff = struct.unpack_from('>2I', blob, pos)
            pos += 8
            name = blob[strings + nameoff:blob.index(0, strings + nameoff)].decode()
            nodes['/'.join(stack) or '/'][name] = blob[pos:pos + size]
            pos = (pos + size + 3) & ~3
        elif token == 4:
            pass
        elif token == 9:
            return nodes
        else:
            raise ValueError(f'Unknown DTB token {token}')
    raise ValueError('Truncated DTB')

def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else 'build/linux')
    manifest = json.loads((out / 'manifest.json').read_text())
    assert manifest['r5_linux_console'] is True
    for name, expected in manifest['outputs'].items():
        assert hashlib.sha256((out / name).read_bytes()).hexdigest() == expected, name
    allowed = {
        'bl31.elf': [(0xfffc0000, 0x100000000)],
        'pmufw.elf': [(0xffdc0000, 0xffde0000)],
        'r5-linux.elf': [(0, 0x10000), (0x20000000, 0x22000000)],
        'entry.elf': [(0x07ff0000, 0x08010000)],
    }
    for name, ranges in allowed.items():
        entry, segments = elf_loads(out / name)
        assert any(lo <= entry < hi for lo, hi in segments), name
        for start, end in segments:
            assert any(lo <= start < end <= hi for lo, hi in ranges), (name, start, end)
        if name == 'entry.elf':
            assert entry == 0x08000000
    nodes = properties((out / 'system.dtb').read_bytes())
    def prop(path, key):
        raw = nodes[path][key]
        return [f'{x:x}' for x in struct.unpack('>' + 'I' * (len(raw) // 4), raw)]
    assert prop('/reserved-memory/packet-pool@10000000', 'reg') == ['0', '10000000', '0', '80000']
    assert prop('/reserved-memory/r5@20000000', 'reg') == ['0', '20000000', '0', '2000000']
    for node in ('packet-pool@10000000', 'r5@20000000'):
        assert prop('/reserved-memory/' + node, 'no-map') == []
    assert prop('/memory@0', 'reg') == ['0', '0', '0', '80000000']
    assert prop('/chosen', 'linux,initrd-start') == ['0', '6000000']
    assert int(prop('/chosen', 'linux,initrd-end')[1], 16) == 0x06000000 + (out / 'rootfs.cpio.gz').stat().st_size
    dt = subprocess.check_output(['dtc', '-I', 'dtb', '-O', 'dts', str(out / 'system.dtb')], text=True)
    for forbidden in ('ethernet@', 'usb@', 'i2c@', 'timer@ff11', 'timer@ff12', 'dma-controller@', 'zynqmp-firmware', 'remoteproc'):
        assert forbidden not in dt, forbidden
    header = (out / 'Image').read_bytes()[:64]
    assert header[56:60] == b'ARM\x64'
    offset, extent = struct.unpack_from('<QQ', header, 8)
    assert offset == 0 and 0 < extent < 0x03e00000
    assert (out / 'rootfs.cpio.gz').stat().st_size < 0x02000000
    print('PASS: boot artifact hashes, load extents, R5/PL DDR reservations and minimal device ownership')

if __name__ == '__main__':
    main()
