# kr260_pl_ethernet.xdc
#
# Real pin/bank/electrical constraints for the KR260 carrier's two PL
# RGMII Ethernet ports (PL0/PL1 -- physical ports 2-3 in this project's
# port numbering, see switch_top.sv). Originally built from Vivado's own
# KR260 board files, then independently cross-checked pin-by-pin against
# the real carrier schematic (docs/xtp743/038-05101-01_sck-kr_reva02_SKIT_20211015.pdf,
# sheets 6/7 "SOM240_1/2 Connector", 16 "Clock Gen, Reset", 20/21 "PL
# GEM2/GEM3 RGMII ETHERNET") -- every pin/net below matches both sources
# exactly. One real discrepancy was found and matters even though it
# doesn't change any pin/bank/IOSTANDARD value here: the PHY is a Texas
# Instruments DP83867CSRGZ per the schematic, not the Marvell
# "M88E1111_BAB1C000" Vivado's board file claims (component
# "pl_gem2"/"pl_gem3" in kr260_carrier/2.0/board.xml) -- relevant for any
# future MDIO register-level PHY driver/config code, which would target
# entirely different registers on the two parts.
#
# Sources:
#   - pin/bank/net names (board file):
#     /tools/Xilinx/2026.1/data/xhub/boards/XilinxBoardStore/boards/Xilinx/kr260_carrier/2.0/board.xml
#     (interfaces "pl_gem2_rgmii"/"pl_gem3_rgmii" and their MDIO/reset/
#     25MHz-oscillator siblings -- Xilinx's own board file names the two
#     PL ports "pl_gem2"/"pl_gem3", continuing the PS's GEM0/GEM1
#     numbering; this project calls them PL0/PL1)
#   - SOM-connector-pin -> actual XCK26 package pin resolution:
#     /tools/Xilinx/2026.1/data/xhub/boards/XilinxBoardStore/boards/Xilinx/kr260_som/2.0/part0_pins.xml
#   - PIN_FUNC/BANK confirmation (both RXC pins are genuinely clock-
#     capable ("_GC_"), both ports are each entirely within one I/O bank
#     -- PL0 in bank 66, PL1 in bank 65) and the legal IDELAYE3
#     DELAY_VALUE range for DELAY_FORMAT="TIME" on this part (0-1100,
#     narrower than UG571's general text suggests): both confirmed by
#     actually querying/simulating against this part in Vivado 2026.1,
#     not assumed from documentation alone.
#
# The 25MHz `ref_clk_25m` pins are each one of four buffered taps (a 1:4
# clock buffer, NB3V1104CDTR2G) off a *single* shared 25MHz oscillator
# (schematic sheet 16) -- the other two taps feed the two PHYs' own
# crystal inputs directly, so this pin is phase-related to the same
# oscillator each PHY uses internally, not an independent/arbitrary
# clock (a board.xml reading alone made these look like two fully
# separate per-port oscillator components; the schematic shows they
# share one source).
#
# `phy_reset_n` is not a direct FPGA-to-PHY reset: per schematic sheet
# 16, this net (HPA05_CCN/HPB05_CCN) is a *reset request* input to a
# board-level sequencer IC (U19, SLG7XL45106, an I2C-configurable
# GreenPAK-style part, I2C addr 0x10/0x11) which — combined with
# power-good and whatever its I2C configuration says, not visible in the
# schematic — produces the PHY's actual RESET_B. The pin/bank/IOSTANDARD
# below is still correct (this net, not the PHY's real reset pin, is
# what's actually routed to the FPGA), but don't assume asserting it
# behaves like a simple, immediate, guaranteed-independent-of-the-other-
# port reset without more information about U19's configuration.
#
# Targets a hypothetical future top-level module (not yet built --
# switch_top.sv deliberately stops at the GMII boundary, see
# rgmii_gmii_adapter.sv's header) instantiating two rgmii_gmii_adapter
# instances named following this project's established per-port-prefix
# convention (pl0_/pl1_, matching e.g. switch_top.sv's own sfp_*/
# gtx_clk_pl0 naming) with ports:
#   <port>_rgmii_txd[3:0], <port>_rgmii_tx_ctl, <port>_rgmii_txc (outputs)
#   <port>_rgmii_rxd[3:0], <port>_rgmii_rx_ctl, <port>_rgmii_rxc (inputs)
#   <port>_mdio (inout), <port>_mdc (out), <port>_phy_reset_n (out -- see above)
#   <port>_ref_clk_25m (in, one of four taps off a shared board oscillator -- see above)
# Rename to match whatever that top level actually calls them once built.
#
# NOT included here -- board data doesn't exist for it (see
# docs/inventory.md's SFP transceiver entry): the SFP cage's GTH channel
# location and reference clock. Also not included: the RX skew-
# compensation IDELAYE3's own reference clock (idelay_refclk_i, 200-
# 800MHz-class per UG571) -- no such clock exists anywhere on this board
# per the schematic; a real bring-up needs to generate one (e.g. via an
# MMCM fed from one of the two `ref_clk_25m` pins below, both confirmed
# clock-capable) as a board-integration-level decision, see
# rgmii_gmii_adapter.sv's header.

# ============================== PL0 (pl_gem2) ==============================

set_property PACKAGE_PIN E1  [get_ports {pl0_rgmii_txd[0]}]
set_property PACKAGE_PIN D1  [get_ports {pl0_rgmii_txd[1]}]
set_property PACKAGE_PIN F2  [get_ports {pl0_rgmii_txd[2]}]
set_property PACKAGE_PIN E2  [get_ports {pl0_rgmii_txd[3]}]
set_property PACKAGE_PIN F1  [get_ports pl0_rgmii_tx_ctl]
set_property PACKAGE_PIN A2  [get_ports pl0_rgmii_txc]
set_property PACKAGE_PIN A1  [get_ports {pl0_rgmii_rxd[0]}]
set_property PACKAGE_PIN B3  [get_ports {pl0_rgmii_rxd[1]}]
set_property PACKAGE_PIN A3  [get_ports {pl0_rgmii_rxd[2]}]
set_property PACKAGE_PIN B4  [get_ports {pl0_rgmii_rxd[3]}]
set_property PACKAGE_PIN A4  [get_ports pl0_rgmii_rx_ctl]
set_property PACKAGE_PIN D4  [get_ports pl0_rgmii_rxc]     ;# clock-capable ("_GC_"), bank 66
set_property PACKAGE_PIN F3  [get_ports pl0_mdio]
set_property PACKAGE_PIN G3  [get_ports pl0_mdc]
set_property PACKAGE_PIN B1  [get_ports pl0_phy_reset_n]   ;# reset REQUEST into U19, not direct -- see header
set_property PACKAGE_PIN C3  [get_ports pl0_ref_clk_25m]   ;# clock-capable ("_GC_"), bank 66

set_property IOSTANDARD LVCMOS18 [get_ports {pl0_rgmii_txd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports pl0_rgmii_tx_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports pl0_rgmii_txc]
set_property IOSTANDARD LVCMOS18 [get_ports {pl0_rgmii_rxd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports pl0_rgmii_rx_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports pl0_rgmii_rxc]
set_property IOSTANDARD LVCMOS18 [get_ports pl0_mdio]
set_property IOSTANDARD LVCMOS18 [get_ports pl0_mdc]
set_property IOSTANDARD LVCMOS18 [get_ports pl0_phy_reset_n]
set_property IOSTANDARD LVCMOS18 [get_ports pl0_ref_clk_25m]

# PL0's recovered RXC (nominal 125MHz for 1000BASE-T; RGMII also runs
# 25MHz/2.5MHz at 100/10Mb -- this project's MAC/PCS stack is 1G-only,
# see docs/inventory.md, so only the 1G rate is constrained)
create_clock -period 8.000 -name pl0_rgmii_rxc [get_ports pl0_rgmii_rxc]
create_clock -period 40.000 -name pl0_ref_clk_25m [get_ports pl0_ref_clk_25m]

# ============================== PL1 (pl_gem3) ==============================

set_property PACKAGE_PIN U9  [get_ports {pl1_rgmii_txd[0]}]
set_property PACKAGE_PIN V9  [get_ports {pl1_rgmii_txd[1]}]
set_property PACKAGE_PIN U8  [get_ports {pl1_rgmii_txd[2]}]
set_property PACKAGE_PIN V8  [get_ports {pl1_rgmii_txd[3]}]
set_property PACKAGE_PIN Y8  [get_ports pl1_rgmii_tx_ctl]
set_property PACKAGE_PIN J1  [get_ports pl1_rgmii_txc]
set_property PACKAGE_PIN H1  [get_ports {pl1_rgmii_rxd[0]}]
set_property PACKAGE_PIN K2  [get_ports {pl1_rgmii_rxd[1]}]
set_property PACKAGE_PIN J2  [get_ports {pl1_rgmii_rxd[2]}]
set_property PACKAGE_PIN H4  [get_ports {pl1_rgmii_rxd[3]}]
set_property PACKAGE_PIN H3  [get_ports pl1_rgmii_rx_ctl]
set_property PACKAGE_PIN K4  [get_ports pl1_rgmii_rxc]     ;# clock-capable ("_GC_"), bank 65
set_property PACKAGE_PIN T8  [get_ports pl1_mdio]
set_property PACKAGE_PIN R8  [get_ports pl1_mdc]
set_property PACKAGE_PIN K1  [get_ports pl1_phy_reset_n]   ;# reset REQUEST into U19, not direct -- see header
set_property PACKAGE_PIN L3  [get_ports pl1_ref_clk_25m]   ;# clock-capable ("_GC_"), bank 65

set_property IOSTANDARD LVCMOS18 [get_ports {pl1_rgmii_txd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports pl1_rgmii_tx_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports pl1_rgmii_txc]
set_property IOSTANDARD LVCMOS18 [get_ports {pl1_rgmii_rxd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports pl1_rgmii_rx_ctl]
set_property IOSTANDARD LVCMOS18 [get_ports pl1_rgmii_rxc]
set_property IOSTANDARD LVCMOS18 [get_ports pl1_mdio]
set_property IOSTANDARD LVCMOS18 [get_ports pl1_mdc]
set_property IOSTANDARD LVCMOS18 [get_ports pl1_phy_reset_n]
set_property IOSTANDARD LVCMOS18 [get_ports pl1_ref_clk_25m]

create_clock -period 8.000 -name pl1_rgmii_rxc [get_ports pl1_rgmii_rxc]
create_clock -period 40.000 -name pl1_ref_clk_25m [get_ports pl1_ref_clk_25m]

# PL0/PL1 are independent, unrelated clock domains (separate PHYs, no
# shared reference) -- not physically capable of interacting, so no
# false-path/exclusion constraints between them should be needed, but
# this hasn't been verified against a real implementation run.
