#!/usr/bin/env python3
"""Audit packaged source contents, interface widths, and clock associations."""
import argparse
import hashlib
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path
from ip_sources import CORES, ROOT, manifest, sources

NS = {'s': 'http://www.spiritconsortium.org/XMLSchema/SPIRIT/1685-2009'}


def digest(path):
    return hashlib.sha256(path.read_bytes()).digest()


def check(catalog):
    staged = {}
    for name in CORES:
        config = manifest(name)
        directory = catalog / name
        tree = ET.parse(directory / 'component.xml').getroot()
        for field, value in {'vendor': 'ghlhub.org', 'library': 'ethernet',
                             'name': name, 'version': config['version']}.items():
            assert tree.findtext('s:' + field, namespaces=NS) == value, f'{name}: wrong {field}'
        views = tree.findall('s:model/s:views/s:view/s:modelName', NS)
        assert views and all(v.text == config['top'] for v in views), f'{name}: wrong HDL top'
        expected = {Path(p).name: ROOT / p for p in config['sources']}
        assert len(expected) == len(config['sources']), f'{name}: ambiguous source names'
        seen = set()
        for node in tree.findall('s:fileSets/s:fileSet/s:file/s:name', NS):
            path = directory / node.text
            assert not Path(node.text).is_absolute() and path.resolve().is_relative_to(directory.resolve()), f'{name}: nonrelocatable file {path}'
            if path.suffix == '.sv':
                assert path.name in expected, f'{name}: unexpected RTL {path}'
                assert digest(path) == digest(expected[path.name]), f'{name}: stale RTL {path}'
                seen.add(path.name)
                staged.setdefault(path.name, str(path))
        assert seen == set(expected), f'{name}: missing packaged sources {set(expected) - seen}'
        buses = {b.findtext('s:name', namespaces=NS): b for b in tree.findall('s:busInterfaces/s:busInterface', NS)}
        associations = {}
        for clock in config['clocks']:
            params = {p.findtext('s:name', namespaces=NS): p.findtext('s:value', namespaces=NS)
                      for p in buses[clock].findall('s:parameters/s:parameter', NS)}
            actual = set(filter(None, (params.get('ASSOCIATED_BUSIF') or '').split(':')))
            assert actual == set(config['clocks'][clock]), f'{name}/{clock}: wrong buses {actual}'
            for bus in actual:
                assert bus in buses, f'{name}: missing interface {bus}'
                assert bus not in associations, f'{name}/{bus}: multiple clocks'
                associations[bus] = clock
            if clock == 'clk':
                assert params.get('ASSOCIATED_RESET') == 'rst_n', f'{name}: missing fabric/control reset'
        ports = {p.findtext('s:name', namespaces=NS): p for p in tree.findall('s:model/s:ports/s:port', NS)}

        def width(port):
            v = ports[port].find('s:wire/s:vector', NS)
            return 1 if v is None else abs(int(v.findtext('s:left', namespaces=NS)) - int(v.findtext('s:right', namespaces=NS))) + 1

        for bus in associations:
            interface = buses[bus]
            kind = interface.find('s:busType', NS).get('{' + NS['s'] + '}name')
            expected_kind = 'axis' if bus.endswith('_axis') else 'aximm'
            assert kind == expected_kind, f'{name}/{bus}: incorrect bus type'
            mapping = {p.findtext('s:logicalPort/s:name', namespaces=NS):
                       p.findtext('s:physicalPort/s:name', namespaces=NS)
                       for p in interface.findall('s:portMaps/s:portMap', NS)}
            expected_mapping = {p[len(bus) + 1:].upper(): p for p in ports if p.startswith(bus + '_')}
            assert mapping == expected_mapping, f'{name}/{bus}: incomplete or crossed port mapping'
            master = bus.startswith('m') or bus.startswith('cpu_m')
            assert interface.find('s:' + ('master' if master else 'slave'), NS) is not None, f'{name}/{bus}: wrong interface mode'
            if kind == 'axis':
                assert {'TDATA', 'TKEEP', 'TVALID', 'TREADY', 'TLAST'} <= mapping.keys(), f'{name}/{bus}: incomplete stream'
                for signal, port in mapping.items():
                    assert width(port) == {'TDATA': 16, 'TKEEP': 2}.get(signal, 1), f'{name}/{port}: wrong width'
                    output = master != (signal == 'TREADY')
                    direction = ports[port].findtext('s:wire/s:direction', namespaces=NS)
                    assert direction == ('out' if output else 'in'), f'{name}/{port}: wrong direction'

        for port in ports:
            if port.endswith('_axis_tdata'):
                assert width(port) == 16, f'{name}/{port}: expected 16-bit packet stream'
            if port.endswith('_axis_tkeep'):
                assert width(port) == 2, f'{name}/{port}: expected two byte enables'
        if name == 'switch_fabric':
            parameters = {p.findtext('s:name', namespaces=NS)
                          for p in tree.findall('s:model/s:modelParameters/s:modelParameter', NS)}
            assert parameters == {'STATS_DDR', 'STATS_DEBUG', 'AGE_TICK_DIVIDE_COUNT'}, f'{name}: invalid HDL parameters {parameters}'
            for port, bits in {'m_axi_ing_wdata': 128, 'm_axi_cpu_rdata': 128,
                               'm_axi_ing_awaddr': 32, 'default_age_i': 9,
                               'link_up_i': 6, 'cpu_rx_ingress_port_o': 3,
                               'stats_req': 6, 'stats_values': 192}.items():
                assert width(port) == bits, f'{name}/{port}: incorrect exported width'
        print(f'PASS: {name}: source contents, stream widths and clock/reset metadata')
    return staged


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('catalog', type=Path, nargs='?', default=ROOT / 'build/ip_catalog')
    parser.add_argument('--bd', type=Path, help='Also elaborate the generated validation block design')
    args = parser.parse_args()
    staged = check(args.catalog.resolve())
    if args.bd:
        bd = args.bd.resolve()
        files = [staged[Path(p).name] for p in sources()]
        files += [str(p) for p in bd.glob('ip/*/sim/*.sv')]
        files += [str(bd / 'sim/partition_validation.v'), str(bd / 'hdl/partition_validation_wrapper.v')]
        subprocess.run(['iverilog', '-g2012', '-s', 'partition_validation_wrapper', '-tnull', *files], check=True)
        print('PASS: generated validation BD elaborates using the packaged source files')
