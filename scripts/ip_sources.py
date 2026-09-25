#!/usr/bin/env python3
"""Resolve the checked-in IP manifests; shared RTL appears only once per build."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORES = ('gem_port', 'pl_port', 'sfp_port', 'switch_fabric', 'management')


def manifest(name):
    return json.loads((ROOT / 'ip_repo' / name / 'manifest.json').read_text())


def sources(names=CORES, board=False):
    paths = []
    for name in names:
        paths.extend(manifest(name)['sources'])
    if board:
        paths.extend(json.loads((ROOT / 'ip_repo/board.json').read_text())['sources'])
    paths = list(dict.fromkeys(paths))
    paths.sort(key=lambda p: not p.endswith('_pkg.sv'))
    for path in paths:
        if not (ROOT / path).is_file():
            raise FileNotFoundError(path)
    return paths


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', choices=CORES, action='append')
    parser.add_argument('--board', action='store_true')
    parser.add_argument('--board-only', action='store_true', help='Physical shell and BD module references; catalog supplies digital RTL')
    parser.add_argument('--assembly', action='store_true')
    parser.add_argument('--kind', choices=('rtl', 'vendor_ip', 'constraints'), default='rtl')
    args = parser.parse_args()
    if args.kind == 'rtl':
        paths = sources((), True) if args.board_only else sources(args.core or CORES, args.board)
        if args.assembly and 'rtl/switch_top.sv' not in paths:
            paths.append('rtl/switch_top.sv')
    else:
        paths = json.loads((ROOT / 'ip_repo/board.json').read_text())[args.kind]
        for path in paths:
            if not (ROOT / path).is_file():
                raise FileNotFoundError(path)
    print('\n'.join(str(ROOT / p) for p in paths))
