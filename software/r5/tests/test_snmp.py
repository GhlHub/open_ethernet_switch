#!/usr/bin/env python3
"""Exercise the exact C engine with independent BER encoding/decoding.
Optional --serve PORT exposes the fixture for Net-SNMP interoperability tests.
"""
import ctypes
import random
import socket
import sys
import unittest
from pathlib import Path

ROOT = (1, 3, 6, 1, 4, 1, 32473, 1)
LIB = ctypes.CDLL(str(Path(sys.argv[1]).resolve()))
LIB.fixture_respond.argtypes = [ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_void_p, ctypes.c_size_t]
LIB.fixture_respond.restype = ctypes.c_size_t
FLAGS = int(sys.argv[2])


def tlv(tag, value):
    n = len(value)
    length = bytes([n]) if n < 128 else bytes([0x82, n >> 8, n & 255])
    return bytes([tag]) + length + value


def integer(x):
    n = max(1, (x.bit_length() + 8) // 8)
    return tlv(2, x.to_bytes(n, 'big', signed=True))


def oid(x):
    encoded = b''
    for arc in (x[0] * 40 + x[1], *x[2:]):
        buf = [arc & 127]
        arc >>= 7
        while arc:
            buf.insert(0, (arc & 127) | 128)
            arc >>= 7
        encoded += bytes(buf)
    return tlv(6, encoded)


def read(data):
    tag, length = data[:2]
    start = 2
    if length & 128:
        count = length & 127
        length = int.from_bytes(data[start:start+count], 'big')
        start += count
    assert start + length <= len(data)
    return tag, data[start:start+length], data[start+length:]


def unoid(data):
    parts, arc = [], 0
    for byte in data:
        arc = (arc << 7) | (byte & 127)
        if not byte & 128:
            parts.append(arc)
            arc = 0
    first = min(parts[0] // 40, 2)
    return (first, parts[0] - first * 40, *parts[1:])


def request(oids, op=0xa0, first=0, second=0, community=b'public',
            version=1, ident=-123, value=b'\x05\0'):
    bindings = b''.join(tlv(0x30, oid(o) + value) for o in oids)
    return tlv(0x30, integer(version) + tlv(4, community) +
               tlv(op, integer(ident) + integer(first) + integer(second) +
                   tlv(0x30, bindings)))


def respond(data, cap=1400):
    out = ctypes.create_string_buffer(cap)
    n = LIB.fixture_respond(data, len(data), out, cap)
    return out.raw[:n]


def decode(data):
    tag, msg, rest = read(data)
    assert tag == 0x30 and not rest
    tag, version, msg = read(msg)
    assert tag == 2 and version == b'\1'
    tag, community, msg = read(msg)
    assert tag == 4 and community == b'public'
    tag, pdu, rest = read(msg)
    assert tag == 0xa2 and not rest
    fields = []
    for _ in range(3):
        tag, val, pdu = read(pdu)
        assert tag == 2
        fields.append(int.from_bytes(val, 'big', signed=True))
    tag, bindings, rest = read(pdu)
    assert tag == 0x30 and not rest
    result = []
    while bindings:
        tag, vb, bindings = read(bindings)
        assert tag == 0x30
        tag, name, vb = read(vb)
        assert tag == 6
        tag, value, rest = read(vb)
        assert not rest
        if tag in (2, 0x41, 0x42, 0x43, 0x46):
            value = int.from_bytes(value, 'big', signed=(tag == 2))
        elif tag == 6:
            value = unoid(value)
        result.append((unoid(name), tag, value))
    return (*fields, result)


class SnmpTests(unittest.TestCase):
    def test_unsigned_and_signed_values(self):
        names = [ROOT+(2,1,3,i) for i in range(1,4)] + [ROOT+(5,4,0), ROOT+(5,12,0)]
        ident, error, index, values = decode(respond(request(names)))
        self.assertEqual((ident,error,index),(-123,0,0))
        self.assertEqual([v[2] for v in values], [2**64-1,2**63,2**32,-12345,-1250])
        self.assertEqual([v[1] for v in values],[0x46]*3+[2,2])

    def test_system_and_health(self):
        names=[(1,3,6,1,2,1,1,2,0),ROOT+(1,7,0),ROOT+(1,9,0)]
        vals=decode(respond(request(names)))[3]
        self.assertEqual([v[2] for v in vals],[ROOT,100,FLAGS])

    def test_port_speeds_and_advertisement(self):
        names=[ROOT+(2,1,12,i) for i in range(1,7)] + [ROOT+(2,1,13,i) for i in range(1,7)]
        vals=decode(respond(request(names)))[3]
        self.assertEqual([v[2] for v in vals],[1000,100,0,0,1000,0,4,3,0,0,0,0])
        self.assertEqual([v[1] for v in vals],[0x42]*12)

    def test_timeout_classes(self):
        vals=decode(respond(request([ROOT+(1,i,0) for i in (6,10,11)])))[3]
        self.assertEqual([v[1] for v in vals],[0x41]*3)
        self.assertEqual([v[2] for v in vals],[18,7,11])

    def test_timeout_indices(self):
        names=[ROOT+(1,i,0) for i in (12,13,14)] + [ROOT+(6,1,1,3,2), ROOT+(6,1,2,0,1)]
        vals=decode(respond(request(names)))[3]
        self.assertEqual([v[2] for v in vals],[0x32,0x33,1,7,11])
        # Two-part table indices still distinguish absent instances/objects.
        vals=decode(respond(request([ROOT+(6,1,1),ROOT+(6,1,1,99,0),ROOT+(6,1,9)])))[3]
        self.assertEqual([v[1] for v in vals],[0x81,0x81,0x80])
        self.assertEqual(decode(respond(request([ROOT+(6,1,1)],op=0xa1)))[3][0][0],ROOT+(6,1,1,0,0))

    def test_exceptions(self):
        names=[ROOT+(2,1,3,99),ROOT+(99,0),ROOT+(1,1)]
        vals=decode(respond(request(names)))[3]
        self.assertEqual([v[1] for v in vals],[0x81,0x80,0x81])
        self.assertEqual(decode(respond(request([(2,99)],op=0xa1)))[3][0][1],0x82)

    def test_walk_sorted_unique_complete(self):
        cursor=(0,0)
        walk=[]
        for _ in range(400):
            val=decode(respond(request([cursor],op=0xa1)))[3][0]
            if val[1]==0x82:
                break
            self.assertGreater(val[0],cursor)
            cursor=val[0]
            walk.append(val)
        expected=200+(100 if FLAGS&2 else 0)+(64 if FLAGS&4 else 0)
        self.assertEqual(len(walk),expected)
        for group,bit in [(3,2),(4,4)]:
            self.assertEqual(any(v[0][:9]==ROOT+(group,) for v in walk), bool(FLAGS&bit))

    def test_bulk_layout_and_bounds(self):
        names=[ROOT+(1,1,0),ROOT+(2,1,3,1),ROOT+(2,1,4,1)]
        vals=decode(respond(request(names,op=0xa5,first=1,second=2)))[3]
        self.assertEqual([v[0] for v in vals], [ROOT+(1,2,0),ROOT+(2,1,3,2),
                         ROOT+(2,1,4,2),ROOT+(2,1,3,3),ROOT+(2,1,4,3)])
        data=respond(request([ROOT]*32,op=0xa5,second=2**31-1))
        self.assertLessEqual(len(data),1400)
        self.assertGreater(len(decode(data)[3]),0)
        self.assertLessEqual(len(decode(data)[3]),64)
        self.assertEqual(decode(respond(request([ROOT],op=0xa5,first=-1,second=-1)))[3],[])
        self.assertEqual(len(decode(respond(request([(2,99)],op=0xa5,second=1000)))[3]),1)

    def test_set_is_read_only(self):
        name=ROOT+(2,1,3,1)
        result=decode(respond(request([name],op=0xa3,value=integer(99))))
        self.assertEqual(result[:3],(-123,17,1))
        self.assertEqual(result[3][0],(name,2,99))
        self.assertEqual(decode(respond(request([name])))[3][0][2],2**64-1)

    def test_oversized_response(self):
        data=respond(request([(1,3,6,1,2,1,1,1,0)]*32))
        self.assertEqual(decode(data)[1:],(1,0,[]))
        self.assertEqual(decode(respond(request([ROOT+(2,1,3,1)]),128))[1:],(1,0,[]))

    def test_invalid_and_unauthorized(self):
        good=request([ROOT+(1,1,0)])
        for n in range(len(good)):
            self.assertEqual(respond(good[:n]),b'')
        for bad in [good+b'\0',request([ROOT],community=b'wrong'),request([ROOT],version=0),
                    request([ROOT],op=0xa2),request([ROOT]*33),b'\x30\x80\0\0',
                    b'\x30\x84\xff\xff\xff\xff',b'\0'*1401]:
            self.assertEqual(respond(bad),b'')
        # Invalid base-128 OID, overflow and unterminated arc inside valid envelopes.
        for encoded in [b'',b'\x80\0',b'\xff'*5,b'\x2b'+b'\xff'*5+b'\x7f']:
            vb=tlv(0x30,tlv(6,encoded)+b'\x05\0')
            data=tlv(0x30,integer(1)+tlv(4,b'public')+tlv(0xa0,
                     integer(1)+integer(0)+integer(0)+tlv(0x30,vb)))
            self.assertEqual(respond(data),b'')

    def test_boundary_request_ids(self):
        for ident in [-2**31,-129,-128,-1,0,127,128,2**31-1]:
            self.assertEqual(decode(respond(request([ROOT],ident=ident)))[0],ident)
        self.assertEqual(respond(request([ROOT],ident=2**31)),b'')

    def test_mutated_messages(self):
        rng=random.Random(937)
        original=request([ROOT+(2,1,3,1)],op=0xa5,second=10)
        for _ in range(10000):
            data=bytearray(original)
            for _ in range(rng.randrange(1,5)):
                data[rng.randrange(len(data))]=rng.randrange(256)
            result=respond(bytes(data))
            if result:
                decode(result)


if __name__=='__main__':
    if '--serve' in sys.argv:
        port=int(sys.argv[-1])
        sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        sock.bind(('127.0.0.1',port))
        print(f'fixture ready on {port}',flush=True)
        while True:
            data,peer=sock.recvfrom(65535)
            reply=respond(data)
            if reply:
                sock.sendto(reply,peer)
    else:
        unittest.main(argv=[sys.argv[0]])
