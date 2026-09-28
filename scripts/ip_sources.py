#!/usr/bin/env python3
"""Resolve the checked-in IP manifests; shared RTL appears only once per build."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORES = ('gem_port', 'pl_port', 'sfp_port', 'switch_fabric', 'management', 'pl_phy_mdio', 'sfp_10g_port', 'sfp_dual_port')


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
    parser.add_argument('--sfp-mode', choices=('1g','10g','dual'), default='1g')
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
    if args.sfp_mode == '10g':
        paths = [p for p in paths if p not in ('rtl/sfp_pcs/gth_sfp_wrapper.sv', 'rtl/sfp_pcs/sfp_pcs_clk_gen.sv', 'rtl/sfp_pcs/ip/gth_sfp_ip.xci', 'rtl/sfp_pcs/ip/sfp_pcs_clk_gen_ip.xci')]
        if args.kind == 'rtl' and (args.board_only or args.board):
            paths.append('rtl/sfp_10g/gth_sfp_10g_wrapper.sv')
    if args.sfp_mode == 'dual':
        paths = [p for p in paths if p not in ('rtl/sfp_pcs/gth_sfp_wrapper.sv','rtl/sfp_pcs/ip/gth_sfp_ip.xci')]
        if args.kind == 'rtl' and (args.board_only or args.board):
            paths += ['rtl/sfp_dual/sfp_dual_drp_rom.sv','rtl/sfp_dual/sfp_dual_reconfigure.sv','rtl/sfp_dual/gth_sfp_dual_wrapper.sv']
    if args.kind == 'constraints' and args.sfp_mode == '1g':
        paths.append('constraints/kr260_sfp_1g_cdc.xdc')
    print('\n'.join(str(ROOT / p) for p in paths))
