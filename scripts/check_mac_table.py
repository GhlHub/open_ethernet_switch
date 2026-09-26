#!/usr/bin/env python3
"""Read cached web MAC records; --refresh explicitly requests one hardware scan."""
import argparse
import http.client
import json
import re
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("host")
p.add_argument("--source")
p.add_argument("--refresh", action="store_true")
args = p.parse_args()
source = (args.source, 0) if args.source else None

def query(path, refresh=False):
    c = http.client.HTTPConnection(args.host, timeout=5, source_address=source)
    try:
        c.request("POST" if refresh else "GET", path,
                  body="refresh=1" if refresh else None,
                  headers={"X-KR260-Request": "1", "Content-Type": "application/x-www-form-urlencoded"})
        r = c.getresponse()
        data = r.read()
        assert r.status in (200, 202), (r.status, data)
        return json.loads(data)
    finally:
        c.close()

s = query("/api/mac-table", args.refresh)
if args.refresh:
    deadline = time.monotonic() + 15
    while s["busy"] and time.monotonic() < deadline:
        time.sleep(.25)
        s = query("/api/mac-table")
    assert not s["busy"] and not s["error"] and s["completed_bytes"] == 32768, s
rows = []
if s["ready"]:
    for page in range(s["pages"]):
        part = query(f"/api/mac-table/{page}")
        assert part["generation"] == s["generation"], "Another client replaced the snapshot; retry"
        for index, mac, mask, age in part["entries"]:
            assert page*128 <= index < (page+1)*128
            assert re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac)
            assert 0 <= mask <= 255 and 1 <= age <= 511
        rows.extend(part["entries"])
    assert len(rows) == s["count"] and len({r[0] for r in rows}) == len(rows)
s["entries"] = rows
print(json.dumps(s, indent=2))
