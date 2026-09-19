# kr260_rgmii_io.xdc -- RGMII I/O timing for the two PL Ethernet ports.
#
# Source of the numbers: DP83867CS/IS/E datasheet (docs/dp83867cs.pdf,
# SNLS504G) section 6.10: TskewR 1.0..2.6 ns (nominal 1.8) at the PHY input,
# TsetupT/TholdT min 1.2 ns (nominal 2) at the PHY output:
#   * TX (FPGA -> PHY): the PHY delays its sampling clock itself (RGMII-ID,
#     enabled by phy_init_seq.sv with delay D = 1.75 ns, TX code 0x6),
#     so the FPGA forwards the clock UNSHIFTED, edge-aligned with the data
#     (both launched from the same 125 MHz clock). The receiver must see the
#     delayed clock 1.0..2.6 ns after the data edge (RGMII v2.0 TskewR), i.e.
#     with D = 1.75 ns the data may arrive from 0.75 ns after to 0.85 ns before
#     the clock at the pins. In set_output_delay terms (setup/hold checked
#     against the opposite-edge capture): max = 4 - 0.75 = 3.25, min = 0.85.
#     (D = 1.25 ns, Xilinx's device-tree value for its own MAC, failed setup
#     by 0.48 ns post-route here and D = 2.0 ns failed hold by 0.15 ns: the
#     data/clock skew at the pins spans about -0.4..+0.65 ns across the two
#     ports and corners, so only a delay near 1.75 ns fits the window.)
#   * RX (PHY -> FPGA): the PHY delays its RX clock (RGMII-ID), so data is
#     centred on the clock edge: setup/hold at the receiver 1.2 ns each
#     around a 4 ns half period => input delay max = 4.0 - 1.2 = 2.8 ns,
#     min = 1.2 ns, both clock edges (DDR).
# The receive clock port clocks (pl{0,1}_rgmii_rxc, 8 ns) are created in
# kr260_pl_ethernet.xdc.

# ---- forwarded transmit clocks (ODDRE1 -> OBUF -> pin) ----
create_generated_clock -name pl0_rgmii_txc_fwd -source [get_pins u_pl/u_rgmii0/u_oddre1_txc/C] -divide_by 1 [get_ports pl0_rgmii_txc]
create_generated_clock -name pl1_rgmii_txc_fwd -source [get_pins u_pl/u_rgmii1/u_oddre1_txc/C] -divide_by 1 [get_ports pl1_rgmii_txc]

# ---- PL0 transmit: edge-aligned, +/-0.5 ns ----
set_output_delay -clock pl0_rgmii_txc_fwd -max 3.250 [get_ports {pl0_rgmii_txd[*] pl0_rgmii_tx_ctl}]
set_output_delay -clock pl0_rgmii_txc_fwd -min 0.850 [get_ports {pl0_rgmii_txd[*] pl0_rgmii_tx_ctl}] -add_delay
set_output_delay -clock pl0_rgmii_txc_fwd -clock_fall -max 3.250 [get_ports {pl0_rgmii_txd[*] pl0_rgmii_tx_ctl}] -add_delay
set_output_delay -clock pl0_rgmii_txc_fwd -clock_fall -min 0.850 [get_ports {pl0_rgmii_txd[*] pl0_rgmii_tx_ctl}] -add_delay
# ---- PL0 receive: centre-aligned, 1.2 ns setup/hold ----
set_input_delay -clock pl0_rgmii_rxc -max 2.800 [get_ports {pl0_rgmii_rxd[*] pl0_rgmii_rx_ctl}]
set_input_delay -clock pl0_rgmii_rxc -min 1.200 [get_ports {pl0_rgmii_rxd[*] pl0_rgmii_rx_ctl}] -add_delay
set_input_delay -clock pl0_rgmii_rxc -clock_fall -max 2.800 [get_ports {pl0_rgmii_rxd[*] pl0_rgmii_rx_ctl}] -add_delay
set_input_delay -clock pl0_rgmii_rxc -clock_fall -min 1.200 [get_ports {pl0_rgmii_rxd[*] pl0_rgmii_rx_ctl}] -add_delay

# ---- PL1 transmit: edge-aligned, +/-0.5 ns ----
set_output_delay -clock pl1_rgmii_txc_fwd -max 3.250 [get_ports {pl1_rgmii_txd[*] pl1_rgmii_tx_ctl}]
set_output_delay -clock pl1_rgmii_txc_fwd -min 0.850 [get_ports {pl1_rgmii_txd[*] pl1_rgmii_tx_ctl}] -add_delay
set_output_delay -clock pl1_rgmii_txc_fwd -clock_fall -max 3.250 [get_ports {pl1_rgmii_txd[*] pl1_rgmii_tx_ctl}] -add_delay
set_output_delay -clock pl1_rgmii_txc_fwd -clock_fall -min 0.850 [get_ports {pl1_rgmii_txd[*] pl1_rgmii_tx_ctl}] -add_delay
# ---- PL1 receive: centre-aligned, 1.2 ns setup/hold ----
set_input_delay -clock pl1_rgmii_rxc -max 2.800 [get_ports {pl1_rgmii_rxd[*] pl1_rgmii_rx_ctl}]
set_input_delay -clock pl1_rgmii_rxc -min 1.200 [get_ports {pl1_rgmii_rxd[*] pl1_rgmii_rx_ctl}] -add_delay
set_input_delay -clock pl1_rgmii_rxc -clock_fall -max 2.800 [get_ports {pl1_rgmii_rxd[*] pl1_rgmii_rx_ctl}] -add_delay
set_input_delay -clock pl1_rgmii_rxc -clock_fall -min 1.200 [get_ports {pl1_rgmii_rxd[*] pl1_rgmii_rx_ctl}] -add_delay

# ---- one IDELAYCTRL per port (different banks): tie each port's IDELAYE3s to its own ----
set_property IODELAY_GROUP rgmii_idly_grp0 [get_cells {u_pl/u_rgmii0/g_idelayctrl.u_idelayctrl}]
set_property IODELAY_GROUP rgmii_idly_grp0 [get_cells -hier -filter {REF_NAME == IDELAYE3 && NAME =~ u_pl/u_rgmii0/*}]
set_property IODELAY_GROUP rgmii_idly_grp1 [get_cells {u_pl/u_rgmii1/g_idelayctrl.u_idelayctrl}]
set_property IODELAY_GROUP rgmii_idly_grp1 [get_cells -hier -filter {REF_NAME == IDELAYE3 && NAME =~ u_pl/u_rgmii1/*}]
