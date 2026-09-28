#!/usr/bin/env python3
"""Regenerate a fresh IP catalog and production BD, then run acceptance gates."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from ip_sources import ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='New directory; existing paths are refused')
    parser.add_argument('--vivado', default=shutil.which('vivado') or '/tools/Xilinx/2026.1/Vivado/bin/vivado')
    parser.add_argument('--resume-implementation', action='store_true',
                        help='Resume an implementation failure after a constraints-only fix; requires unchanged RTL and --output')
    parser.add_argument('--sfp-mode', choices=('1g', '10g', 'dual'), default='1g')
    parser.add_argument('--implement', action='store_true', help='Also route, generate bitstream and timing/CDC reports')
    args = parser.parse_args()
    if args.resume_implementation and (not args.output or not args.implement):
        parser.error('--resume-implementation requires --output and --implement')
    if args.output:
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=args.resume_implementation)
    else:
        parent = ROOT / 'build/ip_refactor'
        parent.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix='acceptance_', dir=parent))
    catalog, project = output / 'catalog', output / 'project'
    env = dict(os.environ, KR260_IP_CATALOG=str(catalog), KR260_PROJECT_DIR=str(project),
               STATS_DDR='1', STATS_DEBUG='1', KR260_SFP_MODE=args.sfp_mode)
    summary = {'complete': False, 'sfp_mode': args.sfp_mode, 'steps': []}
    report = output / 'results.json'
    if args.resume_implementation:
        summary = json.loads(report.read_text())
        assert not summary['complete'] and summary['sfp_mode'] == args.sfp_mode
        prior = summary['steps']
        failed = next(i for i, step in enumerate(prior) if not step['passed'])
        assert prior[failed]['name'] == 'implementation'
        assert all(step['passed'] for step in prior[:failed])
        summary.setdefault('previous_failures', []).extend(prior[failed:])
        summary['steps'] = prior[:failed]
        for step in prior[failed:]:
            log = output / (step['name'] + '.log')
            if log.exists():
                backup = output / (step['name'] + f'.failed-{len(summary["previous_failures"])}.log')
                shutil.copyfile(log, backup)
        # A constraints-only resume must not reuse tests of different RTL.
        from check_ip_catalog import check
        from check_production_bd import check as check_bd
        check(catalog)
        check_bd(project / 'kr260_switch.srcs/sources_1/bd/system/system.bd')

    def save():
        report.write_text(json.dumps(summary, indent=2) + '\n')

    def run(name, command, timeout=1800):
        if args.resume_implementation and any(s['name'] == name and s['passed'] for s in summary['steps']):
            return
        print(f'Running {name}; log: {output / (name + ".log")}', flush=True)
        step = {'name': name, 'command': list(map(str, command)), 'passed': False}
        summary['steps'].append(step)
        save()
        with (output / (name + '.log')).open('w') as log:
            subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                           stderr=subprocess.STDOUT, timeout=timeout, check=True)
        step['passed'] = True
        save()

    def vivado(script, *arguments):
        return [args.vivado, '-mode', 'batch', '-nolog', '-nojournal', '-source',
                script, '-tclargs', *map(str, arguments)]

    python = sys.executable
    save()
    run('package', vivado('ip_repo/package.tcl', catalog))
    run('catalog', [python, 'scripts/check_ip_catalog.py', str(catalog)])
    run('production', vivado('build/build_kr260.tcl', 'bd'))
    bd = project / 'kr260_switch.gen/sources_1/bd/system'
    run('production_audit', [python, 'scripts/check_production_bd.py',
                            str(project / 'kr260_switch.srcs/sources_1/bd/system/system.bd')])
    run('native_tests', [python, 'scripts/check_ip_tests.py', '--output', str(output / 'tests')])
    run('packaged_tests', [python, 'scripts/check_ip_tests.py', '--catalog', str(catalog),
                          '--output', str(output / 'tests')])
    for ddr in ('0', '1'):
        for debug in ('0', '1'):
            run(f'native_regression_{ddr}{debug}', [python, 'scripts/check_ip_equivalence.py',
                '--stats-ddr', ddr, '--stats-debug', debug, '--output', str(output / 'miters')])
    if args.sfp_mode == '1g':
        run('production_equivalence', [python, 'scripts/check_ip_equivalence.py',
            '--production-bd', str(bd), '--catalog', str(catalog), '--output', str(output / 'miters')])
    else:
        # The native switch_top remains the 1G reference: 10G has a different
        # PHY protocol and stream width, so an equality miter is inapplicable.
        # Both source sets run the MAC/PCS, wide DMA and forwarding scoreboards.
        summary['production_equivalence'] = 'not applicable: native reference is 1G'
        save()
    if args.sfp_mode == 'dual':
        run('transceiver_profiles', vivado('scripts/check_sfp_dual_profiles.tcl', output / 'transceiver_profiles'))
        run('transceiver_simulation', vivado('scripts/simulate_sfp_dual_gth.tcl', output / 'transceiver_simulation'))
    if args.implement:
        run('implementation', vivado('ip_repo/implement.tcl', project / 'kr260_switch.xpr'), 14400)
        checkpoint = project / 'kr260_switch.runs/impl_1/kr260_top_routed.dcp'
        run('routed_reports', vivado('ip_repo/review_board.tcl', checkpoint, output / 'reports'))
    summary['complete'] = True
    save()
    print(f'PASS: IP acceptance; report: {report}', flush=True)


if __name__ == '__main__':
    main()
