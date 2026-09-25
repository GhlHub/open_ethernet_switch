"""Extract the digital datapath from Vivado's generated production netlist.

Keep actual generated instance connections and stream nets; substitute the
PS/interconnect, physical pins and CSR controls with the existing testbench.
The immutable prior native assembly supplies the expected boundary mapping.
"""
import re
import subprocess
from pathlib import Path
from ip_sources import ROOT

NATIVE = '09ddfea1a962428eba60b5c3ad32f2bd6717f441'
CELLS = {'fabric': 'u_fabric', 'gem0': 'u_ps_gem0', 'gem1': 'u_ps_gem1',
         'pl0': 'u_pl_gmii0', 'pl1': 'u_pl_gmii1', 'sfp': 'u_sfp0'}


def connections(text, instance):
    match = re.search(r'\b' + instance + r'\s*\(([\s\S]*?)\);', text)
    assert match, instance
    return {p: v.strip() for p, v in re.findall(r'\.(\w+)\s*\(([^()]*)\)', match[1])}


def fixture(bd, out):
    native = subprocess.check_output(['git', 'show', f'{NATIVE}:rtl/switch_top.sv'], cwd=ROOT, text=True)
    board = subprocess.check_output(['git', 'show', f'{NATIVE}:rtl/board/kr260_pl_top.sv'], cwd=ROOT, text=True)
    generated = (bd / 'sim/system.v').read_text()
    actual = {cell: connections(generated, cell) for cell in [*CELLS, 'management']}
    expected = {cell: connections(native, inst) for cell, inst in CELLS.items()}
    header = native[:native.index('\n);') + 3]
    ports = dict((name, direction) for direction, name in re.findall(
        r'\b(input|output)\s+(?:wire|logic)\s*(?:\[[^\]]+\]\s*)*(\w+)', re.sub(r'//[^\n]*', '', header)))
    declarations = re.findall(r'^  wire [^;]+;', generated, re.M)
    wires = {re.search(r'(\w+);$', line)[1] for line in declarations}
    # Separate generated net names from the preserved switch_top port names.
    def rename(text):
        return re.sub(r'\b\w+\b', lambda m: 'bd_' + m[0] if m[0] in wires else m[0], text)
    instances = []
    for cell in CELLS:
        inst = re.search(r'^  (\w+) ' + cell + r'\s*\([\s\S]*?\);', generated, re.M)
        assert inst, cell
        # Rename only connection expressions, never a formal pin name.
        instances.append(re.sub(r'\(([^()]*)\)', lambda m: '(' + rename(m[1]) + ')', inst[0]))
    boundary = {}
    internal = {}
    for cell, pins in expected.items():
        for pin, net in pins.items():
            value = actual[cell].get(pin)
            if net in ports:
                # Unused production outputs still exist on the generated wrapper.
                if not value:
                    assert ports[net] == 'output', (cell, pin)
                    value = cell + '.' + pin
                boundary.setdefault(net, []).append(value)
            elif net.startswith('phy_'):
                internal.setdefault(net, []).append(value)
    for net, values in internal.items():
        assert len(values) == 2 and len(set(values)) == 1 and values[0], (net, values)
    router_ports = ['stats_select', 'gem0_req', 'gem0_acks', 'gem0_values',
                    'gem1_req', 'gem1_acks', 'gem1_values', 'pl0_req', 'pl0_acks',
                    'pl0_values', 'pl1_req', 'pl1_acks', 'pl1_values', 'sfp_req',
                    'sfp_acks', 'sfp_values', 'fabric_req', 'fabric_acks', 'fabric_values']
    router_connections = [f'.{p}({rename(actual["management"][p])})' for p in router_ports]
    for pin in ['stats_request', 'stats_index', 'stats_ack', 'stats_value']:
        router_connections.append(f'.{pin}({pin})')
    instances.append('switch_stats_router stats_router (' + ', '.join(router_connections) + ');')
    # Check management-to-fabric controls against the previous board assembly.
    board_switch = connections(board, 'u_switch')
    board_mgmt = connections(board, 'u_rx_diag')
    for mp, net in board_mgmt.items():
        for sp, sn in board_switch.items():
            if net and net == sn and sp in boundary:
                assert actual['management'][mp] in boundary[sp], (mp, sp)
    assignments = []
    for port, direction in ports.items():
        if port in ['stats_request', 'stats_index', 'stats_ack', 'stats_value']:
            continue
        values = boundary.get(port, [])
        assert values, f'unmapped switch port {port}'
        assert len(set(values)) == 1, (port, values)
        value = rename(values[0])
        lhs, rhs = (value, port) if direction == 'input' else (port, value)
        assignments.append(f'  assign {lhs} = {rhs};')
    result = header + '\n' + '\n'.join(map(rename, declarations)) + '\n'
    result += '\n'.join(instances + assignments) + '\nendmodule\n'
    target = out / 'production_assembly.sv'
    target.write_text(result)
    # Copy only wrappers needed by the digital fixture. Accelerate aging and PCS
    # timers for simulation; production parameters remain unchanged on disk.
    wrappers = []
    for cell in CELLS:
        paths = list(bd.glob(f'ip/system_{cell}_0/sim/*.[sv]*'))
        assert len(paths) == 1, (cell, paths)
        text = paths[0].read_text()
        if cell == 'fabric':
            text, count = re.subn(r'(\.AGE_TICK_DIVIDE_COUNT\()[^)]+', r'\g<1>100', text)
            assert count == 1
        if cell == 'sfp':
            text, count = re.subn(r'(\.AN_(?:BREAK_LINK|LINK_TIMER|IDLE_DETECT)_CYCLES\()[^)]+', r'\g<1>8', text)
            assert count == 3
        path = out / paths[0].name
        path.write_text(text)
        wrappers.append(str(path))
    print('PASS: generated production stream wiring, shared boundaries and management controls')
    return str(target), wrappers
