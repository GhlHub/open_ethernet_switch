# One GTHE4 channel, both quad PLLs: QPLL0=10.3125 GHz, QPLL1=10 GHz.
# The reviewed DRP table changes channel dividers/PCS; PLLs stay at fixed rates.
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name gth_sfp_dual_ip
set_property CONFIG.preset GTH-10GBASE-R [get_ips gth_sfp_dual_ip]
set_property -dict [list CONFIG.CHANNEL_ENABLE X0Y6 \
 CONFIG.TX_MASTER_CHANNEL X0Y6 CONFIG.RX_MASTER_CHANNEL X0Y6 \
 CONFIG.TX_LINE_RATE 10.3125 CONFIG.RX_LINE_RATE 10.3125 \
 CONFIG.TX_REFCLK_FREQUENCY 156.25 CONFIG.RX_REFCLK_FREQUENCY 156.25 \
 CONFIG.TX_USER_DATA_WIDTH 64 CONFIG.RX_USER_DATA_WIDTH 64 \
 CONFIG.TX_INT_DATA_WIDTH 32 CONFIG.RX_INT_DATA_WIDTH 32 \
 CONFIG.LOCATE_COMMON CORE CONFIG.LOCATE_RESET_CONTROLLER CORE \
 CONFIG.LOCATE_TX_USER_CLOCKING EXAMPLE_DESIGN CONFIG.LOCATE_RX_USER_CLOCKING EXAMPLE_DESIGN \
 CONFIG.LOCATE_USER_DATA_WIDTH_SIZING CORE CONFIG.FREERUN_FREQUENCY 50 \
 CONFIG.SECONDARY_QPLL_ENABLE true CONFIG.SECONDARY_QPLL_LINE_RATE 1.25 \
 CONFIG.SECONDARY_QPLL_REFCLK_FREQUENCY 156.25 \
 CONFIG.ENABLE_OPTIONAL_PORTS {gtrefclk01_in qpll0lock_out qpll1lock_out qpll1reset_in drpaddr_in drpdi_in drpen_in drpwe_in drpdo_out drprdy_out drpclk_in tx8b10ben_in rx8b10ben_in txctrl0_in txctrl1_in txctrl2_in rxctrl0_out rxctrl1_out rxctrl2_out rxctrl3_out rxcommadeten_in rxmcommaalignen_in rxpcommaalignen_in txsysclksel_in rxsysclksel_in txpllclksel_in rxpllclksel_in txoutclksel_in rxoutclksel_in rxlpmen_in}] [get_ips gth_sfp_dual_ip]
