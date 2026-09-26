#!/usr/bin/env python3
"""Run current native switch regression or compare packaged wiring to native.

CPU TX ABI 1 intentionally changes the old raw stream contract. Historical
pre-partition equivalence is not claimed. Leaf behavior is checked by focused
scoreboards; the generated/native miter checks assembly wiring and timing.
"""
import argparse
import re
import subprocess
from pathlib import Path
from ip_sources import ROOT, sources

def run(command, log):
    with log.open('w') as out:
        subprocess.run(command, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, check=True, timeout=600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stats-ddr', type=int, choices=(0, 1), default=1)
    parser.add_argument('--stats-debug', type=int, choices=(0, 1), default=1)
    parser.add_argument('--packaged-bd', type=Path, help='Use generated IP simulation wrappers from validate.tcl')
    parser.add_argument('--production-bd', type=Path, help='Generated production system BD directory')
    parser.add_argument('--catalog', type=Path, help='Catalog used to generate --packaged-bd')
    parser.add_argument('--output', type=Path, help='Parent directory for isolated comparison artifacts')
    args = parser.parse_args()
    if args.packaged_bd and (not args.catalog or (args.stats_ddr, args.stats_debug) != (1, 1)):
        parser.error('--packaged-bd requires --catalog and both statistics options enabled')
    suffix = '_production' if args.production_bd else ('_packaged' if args.packaged_bd else '')
    if args.production_bd and (not args.catalog or args.packaged_bd or (args.stats_ddr, args.stats_debug) != (1, 1)):
        parser.error('--production-bd requires --catalog, both counter groups, and no --packaged-bd')
    out = (args.output.resolve() if args.output else ROOT / 'build/ip_refactor') / f'equivalence_{args.stats_ddr}{args.stats_debug}{suffix}'
    out.mkdir(parents=True, exist_ok=True)
    native_only = not (args.packaged_bd or args.production_bd)
    golden = (ROOT / 'rtl/switch_top.sv').read_text()
    header = re.sub(r'//[^\n]*', '', golden[:golden.index('\n);')])
    outputs = re.findall(r'\boutput\s+(?:wire|logic)\s*(?:\[[^\]]+\]\s*)*(\w+)', header)
    clocks = re.findall(r'\binput\s+logic\s+(\w*clk\w*)\s*[,\n]', header)
    golden = re.sub(r'\bmodule switch_top\b', 'module golden_switch_top', golden)
    (out / 'golden_switch_top.sv').write_text(golden)
    tb = (ROOT / 'tb/tb_switch_top.sv').read_text()
    tb = tb.replace('#(.AGE_TICK_DIVIDE_COUNT(100))',
                    f'#(.STATS_DDR({args.stats_ddr}), .STATS_DEBUG({args.stats_debug}), .AGE_TICK_DIVIDE_COUNT(100))')
    # Exercise every statistics bank and slot, including unmapped indices,
    # during packet traffic. Keep the original four-phase mailbox contract.
    tb = tb.replace(') dut (', ') dut (\n    .stats_request(snapshot_req), .stats_index(snapshot_index),')
    tb = tb.replace('module tb_switch_top;', 'module tb_switch_top;\n  logic snapshot_req = 0;\n  logic [7:0] snapshot_index = 0;')
    start = tb.index('  switch_top #(')
    end = tb.index('\n  );', start) + 6
    reference = tb[start:end].replace('switch_top #(', 'golden_switch_top #(', 1).replace(') dut (', ') reference (', 1)
    for name in outputs:
        reference = re.sub(r'\.' + name + r'\s*\([^)]*\)', '.' + name + '()', reference)
    checks = '\n'.join(f'      if (dut.{name} !== reference.{name}) $fatal(1, "equivalence mismatch: {name} actual=%h expected=%h", dut.{name}, reference.{name});' for name in outputs)
    if native_only:
        reference = ''
        checks = ''

    # Connect inputs through the DUT's ports so tied/shared clocks are checked
    # exactly as the original assembly sees them.
    edges = ' or '.join('posedge dut.' + name for name in clocks)
    extra = f'''
  integer comparisons = 0;
  integer snapshots = 0;
  initial begin
    wait (rst_n && axis_rst_n);
    repeat (50) @(negedge axis_clk);
    forever begin
      snapshot_req = 1;
      wait (dut.stats_ack === 1'b1);
      repeat (3) @(negedge axis_clk);
      snapshot_req = 0;
      wait (dut.stats_ack === 1'b0);
      repeat (3) @(negedge axis_clk);
      snapshot_index = snapshot_index + 1'b1;
      snapshots = snapshots + 1;
    end
  end
{reference}
  always @({edges}) begin
    #1;
    if (rst_n && axis_rst_n) begin
{checks}
      comparisons = comparisons + 1;
    end
  end
  final begin
    $display("{'Regression' if native_only else 'Miter'}: %0d clock samples, {len(outputs)} outputs, %0d snapshots", comparisons, snapshots);
  end
'''
    tb = tb.replace('endmodule', extra + '\nendmodule')
    (out / 'tb_miter.sv').write_text(tb)
    files = [str(ROOT / p) for p in sources()]
    files += [str(ROOT / 'rtl/switch_top.sv'), str(out / 'golden_switch_top.sv'),
              str(ROOT / 'tb/axi_mem_bfm.sv'), str(out / 'tb_miter.sv')]
    if args.packaged_bd:
        from check_ip_catalog import check, NS
        from ip_sources import CORES
        import xml.etree.ElementTree as ET
        catalog = args.catalog.resolve()
        check(catalog)
        # Compile the actual staged source contents referenced by IP-XACT.
        # Shared helpers are identical and compiled once, as in the board flow.
        staged = {}
        for name in CORES:
            directory = catalog / name
            tree = ET.parse(directory / 'component.xml').getroot()
            for node in tree.findall('s:fileSets/s:fileSet/s:file/s:name', NS):
                path = directory / node.text
                if path.suffix == '.sv':
                    staged.setdefault(path.name, str(path))
        files = [staged[Path(p).name] for p in sources()] + files[len(sources()):]
        assembly = (ROOT / 'rtl/switch_top.sv').read_text()
        for top, instance, cell in [('switch_fabric', 'u_fabric', 'fabric'),
                                    ('sfp_port_top', 'u_sfp0', 'sfp')]:
            assembly, count = re.subn(top + r' #\([\s\S]*?\) ' + instance,
                                     f'partition_validation_{cell}_0 {instance}', assembly)
            assert count == 1
        for top, instance, cell in [('switch_gem_port', 'u_ps_gem0', 'gem0'),
                                    ('switch_gem_port', 'u_ps_gem1', 'gem1'),
                                    ('pl_gmii_mac_top', 'u_pl_gmii0', 'pl0'),
                                    ('pl_gmii_mac_top', 'u_pl_gmii1', 'pl1')]:
            assembly = assembly.replace(f'{top} {instance}', f'partition_validation_{cell}_0 {instance}')
        (out / 'packaged_assembly.sv').write_text(assembly)
        files[files.index(str(ROOT / 'rtl/switch_top.sv'))] = str(out / 'packaged_assembly.sv')
        files += [str(p) for p in args.packaged_bd.resolve().glob('ip/*/sim/*.sv')]
        # Generated IP wrappers add an `inst` level around the fabric module.
        tb = tb.replace('dut.u_fabric.', 'dut.u_fabric.inst.')
        (out / 'tb_miter.sv').write_text(tb)
    if args.production_bd:
        from production_fixture import fixture
        from check_ip_catalog import check
        staged = check(args.catalog.resolve())
        files = [staged[Path(p).name] for p in sources()] + files[len(sources()):]
        assembly, wrappers = fixture(args.production_bd.resolve(), out)
        files[files.index(str(ROOT / 'rtl/switch_top.sv'))] = assembly
        files += wrappers
        tb = tb.replace('dut.u_fabric.', 'dut.fabric.inst.')
        # The legacy fixture releases reset on sampling edges. Added BD net
        # aliases change delta-cycle ordering; release on the inactive edge
        # so both assemblies receive identical, race-free reset stimulus.
        tb = re.sub(r'repeat \(5\) @\(posedge (\w+)\);(\s+\w*rst_n\w* = 1\'b1;)',
                    r'repeat (5) @(negedge \1);\2', tb)
        (out / 'tb_miter.sv').write_text(tb)
    run(['iverilog', '-g2012', '-s', 'tb_switch_top', '-o', str(out / 'miter.vvp'), *files], out / 'compile.log')
    run(['vvp', str(out / 'miter.vvp')], out / 'run.log')
    result = (out / 'run.log').read_text()
    print(result, end='')
    if 'FAIL' in result or 'ALL TESTS PASSED' not in result:
        raise SystemExit('Current functional regression failed; see ' + str(out / 'run.log'))
    counts = re.search(r'(?:Miter|Regression): (\d+) clock samples, \d+ outputs, (\d+) snapshots', result)
    if not counts or int(counts[1]) == 0 or int(counts[2]) < 256:
        raise SystemExit('Insufficient miter/mailbox coverage')


if __name__ == '__main__':
    main()
