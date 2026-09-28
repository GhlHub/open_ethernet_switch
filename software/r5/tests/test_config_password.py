"""Independent verification of the default admin/admin password record."""
import ctypes
import hashlib
import struct
import sys
import zlib

lib = ctypes.CDLL(sys.argv[1])
config = ctypes.create_string_buffer(1024)
record = ctypes.create_string_buffer(256)
lib.config_defaults(config)
lib.config_encode(config, 7, record)
r = record.raw
assert r[46:78].split(b'\0')[0] == b'admin'
rounds = struct.unpack_from('<I', r, 126)[0]
assert rounds == 100000
assert hashlib.pbkdf2_hmac('sha256', b'admin', r[78:94], rounds) == r[94:126]
assert struct.unpack_from('<I', r, 248)[0] == zlib.crc32(r[:248])
assert r[252:] == b'DONE'
print('PASS: Python independently verifies default admin/admin PBKDF2 verifier and record CRC')

assert struct.unpack_from('<I', r, 8)[0] == 2
assert r[150:152] == bytes([0, 2])
legacy = bytearray(r)
struct.pack_into('<I', legacy, 8, 1)
legacy[150:152] = bytes([0, 0])
struct.pack_into('<I', legacy, 248, zlib.crc32(legacy[:248]))
seq = ctypes.c_uint32()
assert lib.config_decode(ctypes.create_string_buffer(bytes(legacy)), config, ctypes.byref(seq))
lib.config_encode(config, seq.value, record)
assert record.raw[150:152] == bytes([0, 2])
print('PASS: v1 records migrate to disabled STP with RSTP selected')
