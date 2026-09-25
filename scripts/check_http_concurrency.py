#!/usr/bin/env python3
"""Read-only live HTTP concurrency regression; never saves board settings."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
import socket
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host')
    parser.add_argument('--source', help='Bind requests to this workstation IPv4 address')
    parser.add_argument('--requests', type=int, default=120)
    args = parser.parse_args()
    if args.requests < 1:
        parser.error('--requests must be positive')
    source = (args.source, 0) if args.source else None

    def query(path, method='GET', body=None, status=200):
        start = time.monotonic()
        connection = http.client.HTTPConnection(args.host, timeout=5, source_address=source)
        try:
            connection.request(method, path, body=body, headers={
                'Connection': 'close', 'X-KR260-Request': '1',
                'Content-Type': 'application/x-www-form-urlencoded'})
            response = connection.getresponse()
            data = response.read()
            assert response.status == status, (path, response.status, data[:100])
            assert len(data) == int(response.getheader('Content-Length')), path
            if status == 200 and path.startswith('/api/'):
                result = json.loads(data)
                required = {'/api/ports': {'admin', 'physical', 'speed_mbps'},
                            '/api/config': {'macs', 'saved', 'writable'},
                            '/api/statistics': {'capabilities', 'polls', 'ports'}}[path]
                assert required <= result.keys(), (path, result.keys())
            else:
                result = data.decode()
                if status == 200:
                    assert 'KR260' in result and '<html' in result.lower(), path
            return result, time.monotonic() - start
        finally:
            connection.close()

    before, _ = query('/api/ports')
    # Reproduce the previous two-child-socket failure while two workers wait
    # on clients that have connected but have not sent HTTP headers.
    for _ in range(5):
        sockets = []
        try:
            for _ in range(2):
                sockets.append(socket.create_connection((args.host, 80), 5, source))
            query('/api/statistics')
        finally:
            for peer in sockets:
                peer.close()
        time.sleep(.3)
    print('PASS: third client served alongside two idle clients (5 trials)', flush=True)

    paths = ['/statistics', '/configuration', '/api/config', '/api/ports', '/api/statistics']
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(query, [paths[i % len(paths)] for i in range(args.requests)]))
    print(f'PASS: {len(results)} mixed requests, six concurrent clients; '
          f'max response {max(t for _, t in results):.3f}s', flush=True)

    # The bad-auth delay should occupy one worker, not all HTTP service.
    with ThreadPoolExecutor(max_workers=2) as pool:
        rejection = pool.submit(query, '/api/ports', 'POST', 'mask=31', 401)
        time.sleep(.1)
        query('/api/statistics')
        assert not rejection.done(), 'statistics waited for the authentication penalty'
        rejection.result()
    print('PASS: public statistics served during authentication rejection', flush=True)

    # Capacity is deliberately bounded: excess connections may be refused,
    # but closing idle peers must restore normal service without a reboot.
    peers = []
    refused = 0
    try:
        for _ in range(16):
            try:
                peers.append(socket.create_connection((args.host, 80), .5, source))
            except (ConnectionRefusedError, TimeoutError):
                refused += 1
    finally:
        for peer in peers:
            peer.close()
    time.sleep(1)
    query('/api/statistics')
    query('/api/config')
    print(f'PASS: service recovered after idle-client overload '
          f'({len(peers)} connected, {refused} refused/timed out)', flush=True)
    after, _ = query('/api/ports')
    for key in ('admin', 'advertise'):
        assert before[key] == after[key], f'configuration changed: {key}'
    print('PASS: administrator settings unchanged', flush=True)


if __name__ == '__main__':
    main()
