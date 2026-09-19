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
