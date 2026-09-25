#!/usr/bin/env python3
"""Run isolated manifest-owned IP regressions against native or packaged RTL."""
import argparse
import json
import re
import subprocess
from pathlib import Path

from check_ip_catalog import check
from ip_sources import CORES, ROOT, manifest, sources


def run(command, log, timeout):
    with log.open('w') as output:
        subprocess.run(command, cwd=log.parent, stdout=output,
                       stderr=subprocess.STDOUT, timeout=timeout, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', choices=CORES, action='append')
    parser.add_argument('--catalog', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/ip_refactor/ip_tests')
    parser.add_argument('--timeout', type=int, default=120)
    args = parser.parse_args()
    catalog = args.catalog.resolve() if args.catalog else None
    if catalog:
        check(catalog)
    output = args.output.resolve() / ('packaged' if catalog else 'native')
    output.mkdir(parents=True, exist_ok=True)
    results = []
    # Replace any previous success report before running, including on failure.
    report = output / 'results.json'
    def save(complete=False):
        report.write_text(json.dumps({'complete': complete, 'tests': results}, indent=2) + '\n')

    save()
    for core in args.core or CORES:
        config = manifest(core)
        rtl = [str((catalog / core if catalog else ROOT) / p)
               for p in sources([core])]
        # Independently elaborate the actual public IP top, not just leaf DUTs.
        run(['iverilog', '-g2012', '-s', config['top'], '-tnull', *rtl],
            output / f'{core}_elaborate.log', args.timeout)
        tests = json.loads((ROOT / 'ip_repo' / core / 'tests.json').read_text())['tests']
        for test in tests:
            name = core + '_' + test.get('name', test['top'])
            binary = output / f'{name}.vvp'
            log = output / f'{name}.log'
            # Support sources model external boundaries; dependencies inside
            # this IP must always come from its manifest/catalog snapshot.
            support = test.get('support', [])
            assert not set(support) & set(config['sources']), name + ': duplicate support RTL'
            command = ['iverilog', '-g2012', '-s', test['top'], '-o', str(binary)]
            command += ['-D' + d for d in test.get('defines', [])]
            command += [f'-P{test["top"]}.{k}={v}' for k, v in test.get('parameters', {}).items()]
            command += rtl + [str(ROOT / p) for p in support]
            command += [str(ROOT / 'tb' / (test['top'] + '.sv'))]
            try:
                run(command, output / f'{name}_compile.log', args.timeout)
                run(['vvp', str(binary)], log, args.timeout)
                transcript = log.read_text()
                if re.search(r'(?m)^\s*(?:FAIL|FATAL|ERROR)\b|\bTEST\(S\) FAILED\b', transcript):
                    raise RuntimeError('simulator reported failure')
                if not re.search(r'\bPASS(?:ED)?\b', transcript):
                    raise RuntimeError('missing success marker')
            except (subprocess.SubprocessError, RuntimeError) as error:
                results.append({'test': name, 'passed': False, 'error': str(error)})
                save()
                raise SystemExit(f'FAIL: {name}: {error}; logs: {output}') from error
            results.append({'test': name, 'passed': True})
            save()
            print(f'PASS: {name}', flush=True)
    save(complete=True)
    print(f'PASS: {len(results)} IP cases; logs: {output}')


if __name__ == '__main__':
    main()
