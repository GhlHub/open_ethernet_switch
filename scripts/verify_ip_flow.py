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
    parser.add_argument('--implement', action='store_true', help='Also route, generate bitstream and timing/CDC reports')
    args = parser.parse_args()
    if args.output:
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        parent = ROOT / 'build/ip_refactor'
        parent.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix='acceptance_', dir=parent))
    catalog, project = output / 'catalog', output / 'project'
    env = dict(os.environ, KR260_IP_CATALOG=str(catalog), KR260_PROJECT_DIR=str(project),
               STATS_DDR='1', STATS_DEBUG='1')
    summary = {'complete': False, 'steps': []}
    report = output / 'results.json'

    def save():
        report.write_text(json.dumps(summary, indent=2) + '\n')

    def run(name, command, timeout=1800):
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
            run(f'equivalence_{ddr}{debug}', [python, 'scripts/check_ip_equivalence.py',
                '--stats-ddr', ddr, '--stats-debug', debug, '--output', str(output / 'miters')])
    run('production_equivalence', [python, 'scripts/check_ip_equivalence.py',
        '--production-bd', str(bd), '--catalog', str(catalog), '--output', str(output / 'miters')])
    if args.implement:
        run('implementation', vivado('ip_repo/implement.tcl', project / 'kr260_switch.xpr'), 14400)
        checkpoint = project / 'kr260_switch.runs/impl_1/kr260_top_routed.dcp'
        run('routed_reports', vivado('ip_repo/review_board.tcl', checkpoint, output / 'reports'))
    summary['complete'] = True
    save()
    print(f'PASS: IP acceptance; report: {report}', flush=True)


if __name__ == '__main__':
    main()
