#!/usr/bin/env python3
"""Read KR260 accumulated statistics using Net-SNMP; no Python packages needed."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

HEALTH = ('available', 'capabilities', 'polls', 'late_polls', 'saturated_reads',
          'read_timeouts', 'age_ms', 'timestamp_hz', 'build_flags',
          'mailbox_release_timeouts', 'snapshot_response_timeouts',
          'last_release_index', 'last_release_target_index', 'last_response_index')
PORT = ('rx_good_packets', 'rx_bad_packets', 'rx_good_bytes', 'rx_bad_bytes',
        'tx_good_packets', 'tx_bad_packets', 'tx_good_bytes', 'tx_bad_bytes')
DDR = ('bytes', 'bursts', 'latency_cycles', 'max_latency_cycles',
       'address_stall_cycles', 'data_stall_cycles', 'error_responses',
       'outstanding_cycles')
SENSORS = ('ps_temperature_c', 'pl_temperature_c', 'ps_lp_voltage_v',
           'ps_fp_voltage_v', 'ps_aux_voltage_v', 'pl_int_voltage_v',
           'pl_aux_voltage_v', 'pl_bram_voltage_v', 'som_current_a',
           'som_voltage_v', 'som_power_w')


def collect(args, executable):
    root = f'.1.3.6.1.4.1.{args.enterprise}.1'
    cmd = [executable, '-m', '', '-v2c', '-c', args.community, '-Cr10',
           '-t', '2', '-r', '1', '-On', args.host, root]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if result.returncode:
        # Do not print the command line, which contains the community.
        raise RuntimeError(result.stderr.strip() or 'SNMP walk failed')
    values = {}
    for line in result.stdout.splitlines():
        match = re.fullmatch(r'(\.[\d.]+) = (Counter64|Counter32|Gauge32|INTEGER|STRING): (.*)', line)
        if not match:
            continue  # Includes the normal end-of-view marker.
        name, kind, value = match.groups()
        if not name.startswith(root + '.'):
            continue
        key = tuple(int(x) for x in name[len(root)+1:].split('.'))
        values[key] = value.strip('"') if kind == 'STRING' else int(value)
    if (1, 1, 0) not in values:
        raise RuntimeError('Project MIB not found; check address and enterprise number')
    health = {name: values.get((1, i, 0)) for i, name in enumerate(HEALTH, 1)}
    ports = []
    for row in range(1, 7):
        port = {'index': row, 'name': values.get((2, 1, 1, row), f'port {row}'),
                'link': {1: 'up', 2: 'down'}.get(values.get((2, 1, 2, row)), 'unknown')}
        port.update({name: values.get((2, 1, col, row)) for col, name in enumerate(PORT, 3)})
        ports.append(port)
    ddr = []
    for row in range(1, 5):
        if (3, 1, 1, row) in values:
            entry = {'index': row, 'name': values[(3, 1, 1, row)]}
            entry.update({name: values.get((3, 1, col, row)) for col, name in enumerate(DDR, 2)})
            ddr.append(entry)
    debug = [{'index': row, 'name': values[(4, 1, 1, row)],
              'count': values.get((4, 1, 2, row))}
             for row in range(1, 17) if (4, 1, 1, row) in values]
    valid = values.get((5, 1, 0), 0)
    sensors = {'valid_mask': valid, 'errors': values.get((5, 2, 0)),
               'age_ms': values.get((5, 3, 0))}
    for field, name in enumerate(SENSORS, 4):
        bit = 0 if field in (4, 6, 7, 8) else 1 if field in (5, 9, 10, 11) else 2
        value = values.get((5, field, 0))
        sensors[name] = value / (1000 if field < 6 else 1000000) if (
            valid & (1 << bit) and value is not None) else None
    bank_names = ('GEM0 RX', 'GEM0 TX', 'GEM1 RX', 'GEM1 TX', 'PL0', 'PL1',
                  'SFP', 'CPU', 'physical ingress write', 'physical egress read',
                  'CPU write', 'CPU read', 'debug')
    timeouts = []
    for bank, source in enumerate(bank_names):
        slots = 4 if bank < 4 else 16 if bank == 12 else 8
        for slot in range(slots):
            release = values.get((6, 1, 1, bank, slot), 0)
            response = values.get((6, 1, 2, bank, slot), 0)
            if not (release or response):
                continue
            names = PORT[(bank % 2)*4:(bank % 2)*4+4] if bank < 4 else PORT if bank < 8 else DDR
            name = next((d['name'] for d in debug if d['index'] == slot+1), f'event {slot}') if bank == 12 else names[slot]
            timeouts.append({'bank': bank, 'slot': slot, 'index': bank*16+slot,
                             'source': source, 'counter': name,
                             'mailbox_release_timeouts': release,
                             'snapshot_response_timeouts': response})
    return {'time': datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
            'host': args.host, 'health': health, 'ports': ports, 'ddr': ddr,
            'debug': debug, 'sensors': sensors, 'timeouts': timeouts}


def display(data):
    print(f"\n{data['time']}  {data['host']}  accumulated totals since R5 restart")
    h = data['health']
    print('Collection: ' + ', '.join(f'{k}={v}' for k, v in h.items()))
    if h['available'] != 1:
        print('WARNING: collection unavailable; port/DDR/debug totals are not valid.')
    if h['saturated_reads']:
        print('WARNING: saturation recorded; totals may undercount.')
    if h['read_timeouts']:
        print('NOTE: mailbox timeouts recorded; collection may have partial updates.')
    print('Timeout locations (bank and slot are zero-based):')
    for key in ('last_release_index', 'last_release_target_index', 'last_response_index'):
        index = h.get(key)
        description = ('unavailable' if index is None else 'none since restart' if index == 4294967295
                       else f'bank {index >> 4}, slot {index & 15}, index 0x{index:02x}')
        print(f'  {key}: {description}')
    for row in data['timeouts']:
        print(f"  {row['source']} / {row['counter']} (bank {row['bank']}, slot {row['slot']}): "
              f"release={row['mailbox_release_timeouts']}, response={row['snapshot_response_timeouts']}")
    print(f"\n{'Port / direction':27} {'Link':5} {'Good packets':>14} {'Bad packets':>12} {'Good bytes':>16} {'Bad bytes':>12}")
    for port in data['ports']:
        for direction in ('rx', 'tx'):
            numbers = [port[f'{direction}_{kind}'] for kind in ('good_packets', 'bad_packets', 'good_bytes', 'bad_bytes')]
            formatted = [f'{v:,}' if isinstance(v, int) else 'n/a' for v in numbers]
            print(f"{port['name'] + ' ' + direction.upper():27} {port['link']:5} "
                  f'{formatted[0]:>14} {formatted[1]:>12} {formatted[2]:>16} {formatted[3]:>12}')
    print('RX = toward fabric; CPU RX = R5 to fabric. Bytes exclude FCS/preamble/IFG.')
    print('\nDDR (cycles at 100 MHz; maximum is since restart):')
    for entry in data['ddr']:
        print(f"  {entry['name']}: " + ', '.join(f'{k}={entry[k]}' for k in DDR))
    if not data['ddr']:
        print('  Not present in this firmware build.')
    print('\nDebug:')
    for entry in data['debug']:
        print(f"  {entry['name']:26} {entry['count']}")
    if not data['debug']:
        print('  Not present in this firmware build.')
    print('\nSensors (invalid readings shown as n/a; SOM power excludes carrier):')
    for name, value in data['sensors'].items():
        formatted = 'n/a' if value is None else f'{value:.6f}' if isinstance(value, float) else str(value)
        print(f'  {name:26} {formatted}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host', nargs='?', default='10.0.1.214', help='board address (default: %(default)s)')
    parser.add_argument('--community', default=os.environ.get('SNMP_COMMUNITY', 'public'), help='read community; defaults to SNMP_COMMUNITY or public')
    parser.add_argument('--enterprise', type=int, default=32473, help='PEN (default: lab example 32473)')
    parser.add_argument('--interval', type=float, default=0, help='seconds between reads; 0 reads once')
    parser.add_argument('--count', type=int, default=0, help='limit periodic reads; 0 repeats until Ctrl-C')
    parser.add_argument('--json', action='store_true', help='one JSON object per read; sensor values use C/V/A/W')
    parser.add_argument('--snmpbulkwalk', help='path to Net-SNMP snmpbulkwalk')
    args = parser.parse_args()
    if args.interval < 0 or not float('-inf') < args.interval < float('inf') or args.count < 0:
        parser.error('interval must be finite and nonnegative; count must be nonnegative')
    if not 1 <= args.enterprise <= 4294967295:
        parser.error('enterprise number must fit a positive 32-bit integer')
    local = Path(__file__).resolve().parents[1] / 'build/r5/snmp_tools/usr/bin/snmpbulkwalk'
    executable = args.snmpbulkwalk or shutil.which('snmpbulkwalk') or (str(local) if local.is_file() else None)
    if not executable:
        parser.error('snmpbulkwalk not found; install Net-SNMP (Ubuntu/Debian: sudo apt install snmp)')
    try:
        reads = 0
        while True:
            started = time.monotonic()
            data = collect(args, executable)
            if args.json:
                print(json.dumps(data), flush=True)
            else:
                display(data)
                sys.stdout.flush()
            reads += 1
            if not args.interval or (args.count and reads >= args.count):
                break
            time.sleep(max(0, args.interval - (time.monotonic() - started)))
    except KeyboardInterrupt:
        return 0
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        message = 'SNMP walk timed out' if isinstance(error, subprocess.TimeoutExpired) else str(error)
        print(f'Error: {message}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
