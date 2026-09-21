# SFP generated clocks may gain a suffix after changing the GTH source.
# Apply the existing CDC delay bounds to every generated SFP clock variant.
# Clock-domain crossing constraints for the assembled KR260 switch.
# Implementation-only (needs the IP-generated clocks to exist; see
# build/build_kr260.tcl). Clock names are the ones Vivado derives for this
# build's IP instances and would need updating if instances are renamed.
#
# The design crosses between unrelated clocks only through structures meant
# to be CDC-safe (Gray-pointer async_fifo, toggle handshakes, the MACs' own
# synchronizers). Vivado cannot know that and times those paths as if the
# clocks were related, producing meaningless multi-ns failures. Each ordered
# pair of these domains is bounded with

set_max_delay -datapath_only -from [get_clocks clk_pl_0] -to [get_clocks clk_out3_pl_eth_clk_gen_ip] 7.000
set_max_delay -datapath_only -from [get_clocks clk_pl_0] -to [get_clocks clk_out1_pl_eth_clk_gen_ip] 7.000
set_max_delay -datapath_only -from [get_clocks clk_pl_0] -to [get_clocks clk_out1_pl_eth_clk_gen_ip_1] 7.000
set_max_delay -datapath_only -from [get_clocks clk_pl_0] -to [get_clocks clk_out1_sfp_pcs_clk_gen_ip*] 7.000
set_max_delay -datapath_only -from [get_clocks clk_pl_0] -to [get_clocks clk_out2_sfp_pcs_clk_gen_ip*] 7.000
set_max_delay -datapath_only -from [get_clocks clk_out3_pl_eth_clk_gen_ip] -to [get_clocks clk_pl_0] 7.000
set_max_delay -datapath_only -from [get_clocks clk_out3_pl_eth_clk_gen_ip] -to [get_clocks clk_out1_pl_eth_clk_gen_ip_1] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out3_pl_eth_clk_gen_ip] -to [get_clocks clk_out1_sfp_pcs_clk_gen_ip*] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out3_pl_eth_clk_gen_ip] -to [get_clocks clk_out2_sfp_pcs_clk_gen_ip*] 10.000
set_max_delay -datapath_only -from [get_clocks clk_out3_pl_eth_clk_gen_ip] -to [get_clocks clk_gem0_rx_0] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out3_pl_eth_clk_gen_ip] -to [get_clocks clk_gem0_tx_0] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out3_pl_eth_clk_gen_ip] -to [get_clocks clk_gem1_rx_0] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out3_pl_eth_clk_gen_ip] -to [get_clocks clk_gem1_tx_0] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_pl_eth_clk_gen_ip] -to [get_clocks clk_pl_0] 7.000
set_max_delay -datapath_only -from [get_clocks clk_out1_pl_eth_clk_gen_ip] -to [get_clocks clk_out1_pl_eth_clk_gen_ip_1] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_pl_eth_clk_gen_ip] -to [get_clocks clk_out1_sfp_pcs_clk_gen_ip*] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_pl_eth_clk_gen_ip] -to [get_clocks clk_out2_sfp_pcs_clk_gen_ip*] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_pl_eth_clk_gen_ip] -to [get_clocks pl0_rgmii_rxc] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_pl_eth_clk_gen_ip_1] -to [get_clocks clk_pl_0] 7.000
set_max_delay -datapath_only -from [get_clocks clk_out1_pl_eth_clk_gen_ip_1] -to [get_clocks clk_out3_pl_eth_clk_gen_ip] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_pl_eth_clk_gen_ip_1] -to [get_clocks clk_out1_pl_eth_clk_gen_ip] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_pl_eth_clk_gen_ip_1] -to [get_clocks clk_out1_sfp_pcs_clk_gen_ip*] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_pl_eth_clk_gen_ip_1] -to [get_clocks clk_out2_sfp_pcs_clk_gen_ip*] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_pl_eth_clk_gen_ip_1] -to [get_clocks pl1_rgmii_rxc] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_sfp_pcs_clk_gen_ip*] -to [get_clocks clk_pl_0] 7.000
set_max_delay -datapath_only -from [get_clocks clk_out1_sfp_pcs_clk_gen_ip*] -to [get_clocks clk_out3_pl_eth_clk_gen_ip] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_sfp_pcs_clk_gen_ip*] -to [get_clocks clk_out1_pl_eth_clk_gen_ip] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out1_sfp_pcs_clk_gen_ip*] -to [get_clocks clk_out1_pl_eth_clk_gen_ip_1] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out2_sfp_pcs_clk_gen_ip*] -to [get_clocks clk_pl_0] 7.000
set_max_delay -datapath_only -from [get_clocks clk_out2_sfp_pcs_clk_gen_ip*] -to [get_clocks clk_out3_pl_eth_clk_gen_ip] 10.000
set_max_delay -datapath_only -from [get_clocks clk_out2_sfp_pcs_clk_gen_ip*] -to [get_clocks clk_out1_pl_eth_clk_gen_ip] 8.000
set_max_delay -datapath_only -from [get_clocks clk_out2_sfp_pcs_clk_gen_ip*] -to [get_clocks clk_out1_pl_eth_clk_gen_ip_1] 8.000
set_max_delay -datapath_only -from [get_clocks clk_gem0_rx_0] -to [get_clocks clk_out3_pl_eth_clk_gen_ip] 8.000
set_max_delay -datapath_only -from [get_clocks clk_gem0_rx_0] -to [get_clocks clk_gem0_tx_0] 8.000
set_max_delay -datapath_only -from [get_clocks clk_gem0_tx_0] -to [get_clocks clk_out3_pl_eth_clk_gen_ip] 8.000
set_max_delay -datapath_only -from [get_clocks clk_gem0_tx_0] -to [get_clocks clk_gem0_rx_0] 8.000
set_max_delay -datapath_only -from [get_clocks clk_gem1_rx_0] -to [get_clocks clk_out3_pl_eth_clk_gen_ip] 8.000
set_max_delay -datapath_only -from [get_clocks clk_gem1_rx_0] -to [get_clocks clk_gem1_tx_0] 8.000
set_max_delay -datapath_only -from [get_clocks clk_gem1_tx_0] -to [get_clocks clk_out3_pl_eth_clk_gen_ip] 8.000
set_max_delay -datapath_only -from [get_clocks clk_gem1_tx_0] -to [get_clocks clk_gem1_rx_0] 8.000
set_max_delay -datapath_only -from [get_clocks pl0_rgmii_rxc] -to [get_clocks clk_out1_pl_eth_clk_gen_ip] 8.000
set_max_delay -datapath_only -from [get_clocks pl1_rgmii_rxc] -to [get_clocks clk_out1_pl_eth_clk_gen_ip_1] 8.000

# RGMII receive-clock <-> AXI-Lite clock: the CPU-visible sticky diagnostics
# (sticky_xdomain.sv) set in the receive domain and are cleared from clk_pl_0.
set_max_delay -datapath_only -from [get_clocks pl0_rgmii_rxc] -to [get_clocks clk_pl_0] 7.000
set_max_delay -datapath_only -from [get_clocks pl1_rgmii_rxc] -to [get_clocks clk_pl_0] 7.000
set_max_delay -datapath_only -from [get_clocks clk_pl_0] -to [get_clocks pl0_rgmii_rxc] 7.000
set_max_delay -datapath_only -from [get_clocks clk_pl_0] -to [get_clocks pl1_rgmii_rxc] 7.000
