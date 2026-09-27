#!/usr/bin/env python3
"""Read-only live qualification of independent statistics bank collection."""
import argparse
import http.client
import json
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host')
    parser.add_argument('--source', help='Local IPv4 address to bind')
    parser.add_argument('--seconds', type=float, default=30)
    parser.add_argument('--unavailable-bank', type=int, action='append', default=[],
                        help='Zero-based bank expected to have no source-clock progress')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 2 <= args.seconds <= 3600 or any(b not in range(13) for b in args.unavailable_bank):
        parser.error('duration must be 2..3600 seconds; banks must be 0..12')
    expected = set(args.unavailable_bank)
    started = time.monotonic()
    first = last = None
    count = 0
    with args.output.open('w') as log:
        while True:
            connection = http.client.HTTPConnection(args.host, timeout=5,
                source_address=(args.source, 0) if args.source else None)
            try:
                connection.request('GET', '/api/statistics')
                response = connection.getresponse()
                assert response.status == 200, response.status
                sample = json.loads(response.read())
            finally:
                connection.close()
            elapsed = time.monotonic()-started
            log.write(json.dumps({'elapsed_s': elapsed, 'statistics': sample})+'\n')
            log.flush()
            assert sample['available'] and sample['capabilities'] & 0xffffff00 == 0x53540200
            assert len(sample['banks']) == 13
            for b, (state, age, unavailable, faults, status) in enumerate(sample['banks']):
                if b in expected:
                    assert state == 2 and not status & 8, (b, state, status)
                    assert unavailable > 0, (b, unavailable)
                elif state != 0:  # Optional banks absent in a matching build.
                    assert state == 1 and age <= 1500, (b, state, age)
            if first is None:
                first = sample
            else:
                assert sample['polls'] >= last['polls'], 'collector restarted'
                for field in ('read_timeouts', 'late_polls', 'saturated_reads'):
                    assert sample[field] == first[field], (field, first[field], sample[field])
                for b, health in enumerate(sample['banks']):
                    assert health[3] == first['banks'][b][3], ('active-clock fault', b)
            last = sample
            count += 1
            if elapsed >= args.seconds:
                break
            time.sleep(min(.5, args.seconds-elapsed))
    assert last['polls']-first['polls'] >= (args.seconds-1)*3, 'collector polling too slowly'
    for b in expected:
        assert last['banks'][b][1] >= first['banks'][b][1], ('stale age reset', b)
    print(f'PASS: {count} samples over {elapsed:.1f}s; '
          f'{last["polls"]-first["polls"]} polls; unavailable banks {sorted(expected)}; '
          'other implemented banks fresh, no new faults/late polls/saturation')


if __name__ == '__main__':
    main()
