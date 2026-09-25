import base64
import ctypes
import hashlib
import sys
lib=ctypes.CDLL(sys.argv[1])
lib.auth_verify.restype=ctypes.c_bool
lib.config_decode.restype=ctypes.c_bool
cfg=ctypes.create_string_buffer(1024)
lib.config_defaults(cfg)
for password in [b'admin',b'x'*65,bytes(range(128))]:
    for rounds in [1,2,100000]:
        salt=b'0123456789abcdef';out=ctypes.create_string_buffer(32)
        lib.auth_derive(password,len(password),salt,rounds,out)
        assert out.raw==hashlib.pbkdf2_hmac('sha256',password,salt,rounds)
assert lib.auth_verify(cfg,b'Basic '+base64.b64encode(b'admin:admin'))
for raw in [b'admin:wrong',b'wrong:admin',b':admin',b'admin:',b'admin',b'admin:admin\0',b'admin:'+b'x'*129]:
    assert not lib.auth_verify(cfg,b'Basic '+base64.b64encode(raw))
for header in [b'',b'Bearer abc',b'Basic $$$$',b'Basic A===',b'Basic =AAA',b'Basic Zg==AAAA',b'Basic Zh==',b'Basic YWRtaW46YWRtaW4=\r\n',b'Basic '+b'A'*220]:
    assert not lib.auth_verify(cfg,header)
# Changing the record immediately invalidates previous credentials.
record=ctypes.create_string_buffer(256);lib.config_encode(cfg,1,record)
r=bytearray(record.raw);salt=b'new-salt12345678';r[78:94]=salt
r[94:126]=hashlib.pbkdf2_hmac('sha256',b'new password',salt,100000)
import zlib,struct
struct.pack_into('<I',r,248,zlib.crc32(r[:248]));sequence=ctypes.c_uint32()
assert lib.config_decode(bytes(r),cfg,ctypes.byref(sequence))
assert not lib.auth_verify(cfg,b'Basic '+base64.b64encode(b'admin:admin'))
assert lib.auth_verify(cfg,b'Basic '+base64.b64encode(b'admin:new password'))
print('PASS: PBKDF2 reference vectors, default/changed credentials, invalid passwords and strict Basic decoding')
