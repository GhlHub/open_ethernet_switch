# KR260 SFP+ cage constraints (carrier XTP743 rev A02, sheets 7/14/16).
# GTH serial pins and the 156.25 MHz reference (U90) are dedicated transceiver
# pins in bank 224 (GTHE4_CHANNEL_X0Y6 / GTHE4_COMMON_X0Y1), traced through the
# SOM240_2 connector and the K26 SOM pin map -- see docs/board-integration.md.

set_property PACKAGE_PIN Y6 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN Y5 [get_ports sfp_refclk_n]
set_property PACKAGE_PIN R4 [get_ports sfp_txp]
set_property PACKAGE_PIN R3 [get_ports sfp_txn]
set_property PACKAGE_PIN T2 [get_ports sfp_rxp]
set_property PACKAGE_PIN T1 [get_ports sfp_rxn]
create_clock -name sfp_refclk -period 6.400 [get_ports sfp_refclk_p]

# Sideband (HD banks, VCCO = PL_3V3). TX_DISABLE is pulled up on the carrier:
# the module stays off unless the FPGA drives it low.
set_property PACKAGE_PIN J12 [get_ports sfp_los]
set_property PACKAGE_PIN A10 [get_ports sfp_tx_fault]
set_property PACKAGE_PIN W10 [get_ports sfp_mod_abs]
set_property PACKAGE_PIN Y10 [get_ports sfp_tx_disable]
set_property IOSTANDARD LVCMOS33 [get_ports {sfp_los sfp_tx_fault sfp_mod_abs sfp_tx_disable}]

# SFP LEDs (HPA13P/N, VCCO_HPA = 1.8 V; gate drivers, high = on)
set_property PACKAGE_PIN G8 [get_ports {sfp_led[0]}]
set_property PACKAGE_PIN F7 [get_ports {sfp_led[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {sfp_led[*]}]

# Module management I2C (SFF-8472 EEPROM at 0xA0/0xA2): SDA = HDB17 (SOM240_2 B50),
# SCL = HDB16_CC (B49), both PL pins in the same 3.3 V HD bank as the sideband
# signals; the carrier fits 4.7k pull-ups (R334-R339), so the AXI IIC's
# open-drain IOBUFs need none. 100 kHz.
set_property PACKAGE_PIN AC11 [get_ports sfp_iic_sda_io]
set_property PACKAGE_PIN AB11 [get_ports sfp_iic_scl_io]
set_property IOSTANDARD LVCMOS33 [get_ports {sfp_iic_sda_io sfp_iic_scl_io}]
# 100 kHz open-drain bus, sampled through the IIC core's own synchronizers.
set_false_path -to   [get_ports {sfp_iic_sda_io sfp_iic_scl_io}]
set_false_path -from [get_ports {sfp_iic_sda_io sfp_iic_scl_io}]

# Slow sideband pins: inputs pass through 2-flop synchronizers and ms-scale
# debouncing in sfp_sideband.sv; TX_DISABLE is a registered static level.
set_false_path -from [get_ports {sfp_los sfp_mod_abs sfp_tx_fault}]
set_false_path -to   [get_ports sfp_tx_disable]
