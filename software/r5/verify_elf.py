"""Check linked R5 vectors and memory ownership, without running hardware."""
import struct
import subprocess
import sys
from pathlib import Path

elf = Path(sys.argv[1])
nm = sys.argv[2]
raw = elf.read_bytes()
assert raw[:6] == b'\x7fELF\x01\x01', 'expected ELF32 little endian'
hdr = struct.unpack_from('<16sHHIIIIIHHHHHH', raw)
assert hdr[2] == 40, 'expected ARM'
symbols = {}
for line in subprocess.check_output([nm, str(elf)], text=True).splitlines():
    fields = line.split()
    if len(fields) == 3:
        symbols[fields[2]] = int(fields[0], 16)
assert symbols['_vector_table'] == symbols['_freertos_vector_table'] == 0
assert hdr[4] == symbols['_boot'] < 0x10000
vectors = None
for i in range(hdr[10]):
    p = struct.unpack_from('<IIIIIIII', raw, hdr[5] + i * hdr[9])
    kind, offset, va, pa, filesz, memsz, flags, align = p
    if kind != 1:
        continue
    assert va == pa, 'firmware must use identity addresses'
    assert (pa + memsz <= 0x10000 or
            0x20000000 <= pa <= pa + memsz <= 0x22000000), 'unexpected load region'
    if pa == 0:
        vectors = raw[offset:offset + filesz]
assert vectors is not None
for offset, handler in [(8, 'FreeRTOS_SWI_Handler'), (24, 'FreeRTOS_IRQ_Handler')]:
    instruction = struct.unpack_from('<I', vectors, offset)[0]
    assert instruction & 0xfffff000 == 0xe59ff000, 'expected ARM PC-relative LDR'
    literal = offset + 8 + (instruction & 0xfff)
    assert struct.unpack_from('<I', vectors, literal)[0] == symbols[handler]
assert not subprocess.check_output([nm, '--undefined-only', str(elf)], text=True).strip()
print('PASS: R5 entry, RTOS low vectors, resolved symbols and reserved memory ranges')
