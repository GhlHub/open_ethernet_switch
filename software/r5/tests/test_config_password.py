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
