"""Summarize paired Vivado ILA CSV captures without assuming equal clock rates."""
import argparse
import csv
import json
from pathlib import Path


def read_csv(path):
    with path.open() as f:
        rows = csv.reader(f)
        names, radix = next(rows), next(rows)
        bases = [16 if r == 'HEX' else 2 if r == 'BIN' else 10 for r in radix]
        return [{n: int(v, base) for n, v, base in zip(names, row, bases)}
                for row in rows]


def column(rows, suffix):
    names = [n for n in rows[0] if n.endswith(suffix)]
    if len(names) != 1:
        raise ValueError(f'Expected one column ending {suffix}: {names}')
    return names[0]


def analyze(directory):
    gem = read_csv(directory / 'gem.csv')
    feed = read_csv(directory / 'feed.csv')
    data_key = column(gem, 'gem1_tx_r_data_o[7:0]')
    word_key = column(feed, '/din[17:0]')
    write_key = column(feed, '/wr_en')
    status_key = column(gem, 'emio_enet1_tx_r_status[3:0]')
    empty_suffix = '/fifo_empty' if any(k.endswith('/fifo_empty') for k in gem[0]) else '/xempty'
    empty_key = column(gem, empty_suffix)
    observed = bytes(r[data_key] for r in gem if r['gem1_tx_r_valid_o'])
    expected = bytearray()
    feed_eop = []
    for r in feed:
        if r[write_key]:
            word = r[word_key]
            expected.append(word & 255)
            if word & 0x10000:
                expected.append((word >> 8) & 255)
            if word & 0x20000:
                feed_eop.append(r['Sample in Buffer'])
    report = dict(feed_bytes=len(expected), gem_bytes=len(observed),
                  byte_stream_equal=observed == expected, feed_eop_samples=feed_eop)
    for signal in ('sop', 'eop', 'underflow', 'flushed'):
        report[signal + '_samples'] = [r['Sample in Buffer'] for r in gem
                                      if r[f'gem1_tx_r_{signal}_o']]
    report['empty_during_valid'] = sum(bool(r[empty_key] and r['gem1_tx_r_valid_o']) for r in gem)
    for name, key in [('status', status_key), ('completion', 'gem1_dma_tx_end_tog_i'),
                      ('ack', 'gem1_dma_tx_status_tog_o')]:
        last = gem[0][key]
        changes = []
        for r in gem[1:]:
            if r[key] != last:
                changes.append([r['Sample in Buffer'], r[key]])
                last = r[key]
        report[name + '_changes'] = changes
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, nargs='?', default=Path('build/gem1_debug'))
    args = parser.parse_args()
    print(json.dumps(analyze(args.directory), indent=2))
