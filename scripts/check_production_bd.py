#!/usr/bin/env python3
"""Audit the production BD's firmware ABI and PS/DMA/physical-shell wiring."""
import argparse
import json
import subprocess
from pathlib import Path
from ip_sources import ROOT
from production_fixture import NATIVE, CELLS, connections


def check(path, compare_physical=False):
    design = json.loads(path.read_text())['design']
    scalar = [set(n['ports']) for n in design['nets'].values()]
    interfaces = [set(n['interface_ports']) for n in design['interface_nets'].values()]

    def connected(*pins, bus=False):
        assert any(set(pins) <= net for net in (interfaces if bus else scalar)), pins

    kinds = dict(zip(CELLS, ['switch_fabric', 'gem_port', 'gem_port', 'pl_port', 'pl_port', 'sfp_port']))
    kinds['management'] = 'management'
    for cell, kind in kinds.items():
        assert design['components'][cell]['vlnv'] == f'ghlhub.org:ethernet:{kind}:1.0'
    for option in ['AN_BREAK_LINK_CYCLES', 'AN_LINK_TIMER_CYCLES', 'AN_IDLE_DETECT_CYCLES']:
        assert design['components']['sfp']['parameters'][option]['value'] == '1250000', option
    for cell, width, value in [('default_age', '9', '300'), ('mac_enable', '1', '1')]:
        params = design['components'][cell]['parameters']
        assert params.get('CONST_WIDTH', {}).get('value', '1') == width
        assert params.get('CONST_VAL', {}).get('value', '1') == value
    for option in ['STATS_DDR', 'STATS_DEBUG']:
        values = [design['components'][c].get('parameters', {}).get(option, {}).get('value', '0') for c in ['fabric', 'management']]
        assert values[0] == values[1] and values[0] in ['0', '1'], (option, values)
    for pin in ['S00_AXI_awcache', 'S01_AXI_arcache', 'S02_AXI_awcache', 'S02_AXI_arcache']:
        connected('ddr_cache_zero/dout', 'sc_ddr/' + pin)
    params = design['components']['ddr_cache_zero']['parameters']
    assert params['CONST_WIDTH']['value'] == '4' and params['CONST_VAL']['value'] == '0'
    for i, cell in enumerate(['gem0', 'gem1', 'pl0', 'pl1', 'sfp']):
        connected(f'{cell}/m_axis', f'fabric/s{i:02}_axis', bus=True)
        connected(f'{cell}/s_axis', f'fabric/m{i:02}_axis', bus=True)
    for a, b in [('fabric/cpu_s_axis', 'dma/M_AXIS_MM2S'), ('fabric/cpu_m_axis', 'dma/S_AXIS_S2MM'),
                 ('fabric/m_axi_ing', 'sc_ddr/S00_AXI'), ('fabric/m_axi_egr', 'sc_ddr/S01_AXI'),
                 ('fabric/m_axi_cpu', 'sc_ddr/S02_AXI'), ('sc_ddr/M00_AXI', 'ps/S_AXI_HP0_FPD'),
                 ('dma/M_AXI_SG', 'sc_dma/S00_AXI'), ('dma/M_AXI_MM2S', 'sc_dma/S01_AXI'),
                 ('dma/M_AXI_S2MM', 'sc_dma/S02_AXI'), ('sc_dma/M00_AXI', 'ps/S_AXI_HP1_FPD')]:
        connected(a, b, bus=True)
    for i, bus in enumerate(['pl0/s_axi', 'pl1/s_axi', 'sfp/s_axi', 'mdio0_s_axi', 'mdio1_s_axi',
                             'dma/S_AXI_LITE', 'sfp_iic/S_AXI', 'management/s_axi']):
        connected(f'sc_ctl/M{i:02}_AXI', bus, bus=True)
    connected('ps/pl_clk0', 'management/clk', 'fabric/axis_clk', 'pl0/axis_clk', 'pl1/axis_clk', 'sfp/axis_clk')
    connected('rst150/peripheral_aresetn', 'management/rst_n', 'fabric/axis_rst_n', 'pl0/axis_rst_n', 'pl1/axis_rst_n', 'sfp/axis_rst_n')
    for cell in CELLS:
        connected('fabric_clk_o', cell + '/clk')
        connected('fabric_rst_n_o', cell + '/rst_n')
    for g in [0, 1]:
        for direction in ['rx', 'tx']:
            connected(f'gem{g}/gem_{direction}_clk', f'ps/fmio_gem{g}_fifo_{direction}_clk_to_pl_bufg', f'gem{g}_{direction}_clk')
            connected(f'gem{g}_{direction}_rst_n', f'gem{g}/gem_{direction}_rst_n')
        for stem in ['rx_w_data', 'rx_w_wr', 'rx_w_sop', 'rx_w_eop', 'rx_w_err', 'rx_w_flush', 'rx_w_status', 'tx_r_rd', 'tx_r_status', 'dma_tx_end_tog']:
            connected(f'ps/emio_enet{g}_{stem}', f'gem{g}/{stem}_i')
        for stem in ['rx_w_overflow', 'tx_r_data_rdy', 'tx_r_valid', 'tx_r_data', 'tx_r_sop', 'tx_r_eop', 'tx_r_err', 'tx_r_underflow', 'tx_r_flushed', 'tx_r_control', 'dma_tx_status_tog']:
            connected(f'ps/emio_enet{g}_{stem}', f'gem{g}/{stem}_o')
    for i, cell in enumerate(['pl0', 'pl1', 'sfp']):
        connected(cell + '/interrupt', f'irq/In{i*2}')
        connected(cell + '/mac_irq', f'irq/In{i*2+1}')
    connected('management/link_irq_o', 'irq1/In1')
    actual = {s['address_block']: (int(s['offset'], 16), s['range']) for s in design['addressing']['/ps']['address_spaces']['Data']['segments'].values()}
    expected = {'/dma/S_AXI_LITE/Reg': (0x80000000, '64K'), '/mdio0_s_axi/Reg': (0x80010000, '64K'),
                '/mdio1_s_axi/Reg': (0x80020000, '64K'), '/sfp_iic/S_AXI/Reg': (0x80030000, '64K'),
                '/pl0/s_axi/reg0': (0x80040000, '256K'), '/pl1/s_axi/reg0': (0x80080000, '256K'),
                '/sfp/s_axi/reg0': (0x800C0000, '256K'), '/management/s_axi/reg0': (0x80100000, '64K')}
    assert actual == expected, actual
    for master in ['m_axi_ing', 'm_axi_egr', 'm_axi_cpu']:
        segments = design['addressing']['/fabric']['address_spaces'][master]['segments'].values()
        assert any(s['address_block'] == '/ps/SAXIGP2/HP0_DDR_LOW' and int(s['offset'], 16) == 0 and s['range'] == '2G' for s in segments), master
    print('PASS: production catalog cells, packet/DDR/control/GEM/IRQ wiring and register map')
    if compare_physical:
        # Physical shell instances must retain their original pin connections.
        previous = subprocess.check_output(['git', 'show', f'{NATIVE}:rtl/board/kr260_pl_top.sv'], cwd=ROOT, text=True)
        current = (ROOT / 'rtl/board/kr260_pl_top.sv').read_text()
        physical = ['u_clkgen0', 'u_clkgen1', 'u_rgmii0', 'u_rgmii1', 'u_mdio0', 'u_mdio1', 'u_gth',
                    'u_sfp_clkgen', 'u_sfp_sideband', 'u_gem0_rx_rst', 'u_gem0_tx_rst', 'u_gem1_rx_rst', 'u_gem1_tx_rst']
        for instance in physical:
            assert connections(previous, instance) == connections(current, instance), instance
        print('PASS: physical instance connections match the previous native assembly')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bd', type=Path)
    parser.add_argument('--compare-physical-baseline', action='store_true', help='Also compare physical shell wiring with the prior Git checkpoint')
    args = parser.parse_args()
    check(args.bd.resolve(), args.compare_physical_baseline)
