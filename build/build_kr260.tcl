# Reproducible KR260 switch build: PS + AXI interconnect + AXI DMA block design
# around rtl/board/kr260_pl_top.sv (module reference).
#
#   cd build && vivado -mode batch -source build_kr260.tcl -nolog -nojournal \
#       -tclargs [bd|synth|impl]      (default: synth)
#
# Generated project lives in build/vivado_kr260/ (git-ignored).
set stage [expr {[llength $argv] ? [lindex $argv 0] : "synth"}]
set here  [file dirname [file normalize [info script]]]
set root  [file dirname $here]
set proj  $here/vivado_kr260
set part  xck26-sfvc784-2LV-c

file delete -force $proj
create_project kr260_switch $proj -part $part
# ---- vendor IP: copy the checked-in .xci files so generated products stay out of rtl/ ----
file mkdir $proj/ip
foreach x {sfp_pcs/ip/gth_sfp_ip.xci sfp_pcs/ip/sfp_pcs_clk_gen_ip.xci pl_gmii/ip/pl_eth_clk_gen_ip.xci} {
  file copy -force $root/rtl/$x $proj/ip/
  import_ip $proj/ip/[file tail $x]
}

set_property board_part xilinx.com:kr260_som:part0:2.0 [current_project]
set_property target_language Verilog [current_project]
set_property XPM_LIBRARIES {XPM_MEMORY XPM_CDC} [current_project]

# ---- RTL (synthesizable sources only: no *_sim_model.sv) ----
set rtl {}
foreach f [glob -nocomplain -directory $root/rtl -types f *.sv */*.sv] {
  if {![string match *_sim_model.sv $f]} { lappend rtl $f }
}
add_files -norecurse $rtl
set_property file_type SystemVerilog [get_files -filter {NAME =~ *.sv}]
# packages first so import statements resolve
foreach pkg [get_files -filter {NAME =~ *_pkg.sv}] { }
update_compile_order -fileset sources_1

# ---- constraints ----
add_files -fileset constrs_1 -norecurse [glob $root/constraints/*.xdc]
# the crossing constraints reference IP-generated clocks: implementation only
set_property USED_IN {implementation} [get_files $root/constraints/kr260_clocks.xdc]

# ---- block design ----
create_bd_design system

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
# The SOM preset does not configure the GEMs (their PHYs are on the carrier):
#   GEM0 = SGMII PHY (DP83867 @0x04) on PS-GTR lane 0, ref = U87 125 MHz on GTR_REFCLK0
#   GEM1 = RGMII PHY (DP83867 @0x08) on MIO38-49; the shared PS MDIO bus is MIO50-51
# Both in external-FIFO mode (the switch's ps_gem_axis_bridge sits on the FIFO ports).
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP2 {1}  CONFIG.PSU__USE__M_AXI_GP0 {0} CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__S_AXI_GP2 {1}  CONFIG.PSU__USE__S_AXI_GP3 {1} \
  CONFIG.PSU__USE__IRQ0 {1} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {150} \
  CONFIG.PSU__FPGA_PL1_ENABLE {1} CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ {50} \
  CONFIG.PSU__ENET0__PERIPHERAL__ENABLE {1} CONFIG.PSU__ENET0__PERIPHERAL__IO {GT Lane0} CONFIG.PSU__ENET0__FIFO__ENABLE {1} \
  CONFIG.PSU__GEM0__REF_CLK_SEL {Ref Clk0} CONFIG.PSU__GEM0__REF_CLK_FREQ {125} \
  CONFIG.PSU__ENET1__PERIPHERAL__ENABLE {1} CONFIG.PSU__ENET1__PERIPHERAL__IO {MIO 38 .. 49} CONFIG.PSU__ENET1__FIFO__ENABLE {1} \
  CONFIG.PSU__ENET1__GRP_MDIO__ENABLE {1} CONFIG.PSU__ENET1__GRP_MDIO__IO {MIO 50 .. 51} \
  CONFIG.PSU__CRL_APB__GEM0_REF_CTRL__FREQMHZ {125} CONFIG.PSU__CRL_APB__GEM1_REF_CTRL__FREQMHZ {125} \
] $ps

# AXI DMA for the CPU port: 16-bit streams, scatter-gather, DRE for unaligned buffers
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma]
set_property -dict [list \
  CONFIG.c_include_sg {1} CONFIG.c_sg_include_stscntrl_strm {0} CONFIG.c_sg_length_width {16} \
  CONFIG.c_m_axis_mm2s_tdata_width {16} CONFIG.c_s_axis_s2mm_tdata_width {16} CONFIG.c_m_axi_mm2s_data_width {32} CONFIG.c_m_axi_s2mm_data_width {32} \
  CONFIG.c_include_mm2s_dre {1} CONFIG.c_include_s2mm_dre {1} \
  CONFIG.c_mm2s_burst_size {16} CONFIG.c_s2mm_burst_size {16} \
] $dma

# reset for the 150 MHz control domain
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst150]

# AXI-Lite control fabric: PS HPM0_LPD -> {3 MAC, 2 MDIO, DMA}
set sc_ctl [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_ctl]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {6} CONFIG.NUM_CLKS {2}] $sc_ctl
# DDR fabric: switch masters -> HP0, DMA masters -> HP1
set sc_ddr [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_ddr]
set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] $sc_ddr
set sc_dma [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_dma]
set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] $sc_dma

set irq [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq]
set_property -dict [list CONFIG.NUM_PORTS {8}] $irq

# ---- external ports: names deliberately identical to kr260_pl_top's, so
# rtl/board/kr260_top.sv can connect the BD wrapper to it name-for-name (a
# module reference is not usable: kr260_pl_top contains vendor IP) ----
proc ext_intf {pin name mode} {
  set p [make_bd_intf_pins_external -name $name $pin]
  return $p
}

# clocks / resets
# PL0 requested at 150 MHz; the PS clock divider network produces ~142.857 MHz
# (the actual value propagates to the AXI-Lite domain; see docs/inventory.md)
create_bd_port -dir O -type clk axis_clk
create_bd_port -dir O -type rst axis_rst_n
create_bd_port -dir O -type clk freerun_clk
create_bd_port -dir O -type rst ps_rst_n
create_bd_port -dir I -type clk -freq_hz 62500000 fabric_clk_o
create_bd_port -dir I -type rst fabric_rst_n_o
connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_ports axis_clk] [get_bd_pins ps/maxihpm0_lpd_aclk] \
  [get_bd_pins rst150/slowest_sync_clk] [get_bd_pins sc_ctl/aclk]
connect_bd_net [get_bd_pins ps/pl_clk1] [get_bd_ports freerun_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_ports ps_rst_n] [get_bd_pins rst150/ext_reset_in]
connect_bd_net [get_bd_pins rst150/peripheral_aresetn] [get_bd_ports axis_rst_n] [get_bd_pins sc_ctl/aresetn]
foreach p {sc_ctl/aclk1 sc_ddr/aclk sc_dma/aclk dma/s_axi_lite_aclk dma/m_axi_sg_aclk dma/m_axi_mm2s_aclk dma/m_axi_s2mm_aclk ps/saxihp0_fpd_aclk ps/saxihp1_fpd_aclk} {
  connect_bd_net [get_bd_ports fabric_clk_o] [get_bd_pins $p]
}
foreach p {sc_ddr/aresetn sc_dma/aresetn dma/axi_resetn} {
  connect_bd_net [get_bd_ports fabric_rst_n_o] [get_bd_pins $p]
}

set_property -dict [list \
  CONFIG.FREQ_HZ [get_property CONFIG.FREQ_HZ [get_bd_pins ps/pl_clk0]] \
  CONFIG.ASSOCIATED_BUSIF {pl0_s_axi:pl1_s_axi:sfp_s_axi:mdio0_s_axi:mdio1_s_axi} \
  CONFIG.ASSOCIATED_RESET {axis_rst_n}] [get_bd_ports axis_clk]
set_property -dict [list \
  CONFIG.ASSOCIATED_BUSIF {m_axi_ing:m_axi_egr:m_axi_cpu:cpu_s_axis:cpu_m_axis} \
  CONFIG.ASSOCIATED_RESET {fabric_rst_n_o}] [get_bd_ports fabric_clk_o]
set_property -dict [list CONFIG.FREQ_HZ [get_property CONFIG.FREQ_HZ [get_bd_pins ps/pl_clk1]]] [get_bd_ports freerun_clk]

# AXI-Lite control: PS HPM0_LPD -> {3 MAC, 2 MDIO, DMA}
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_LPD] [get_bd_intf_pins sc_ctl/S00_AXI]
set i 0
foreach n {pl0_s_axi pl1_s_axi sfp_s_axi mdio0_s_axi mdio1_s_axi} {
  make_bd_intf_pins_external -name $n [get_bd_intf_pins sc_ctl/M0${i}_AXI]
  incr i
}
connect_bd_intf_net [get_bd_intf_pins sc_ctl/M05_AXI] [get_bd_intf_pins dma/S_AXI_LITE]

# DDR: switch masters -> HP0, DMA masters -> HP1
foreach {n si} {m_axi_ing S00_AXI m_axi_egr S01_AXI m_axi_cpu S02_AXI} {
  make_bd_intf_pins_external -name $n [get_bd_intf_pins sc_ddr/$si]
}
connect_bd_intf_net [get_bd_intf_pins sc_ddr/M00_AXI] [get_bd_intf_pins ps/S_AXI_HP0_FPD]
connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_SG]   [get_bd_intf_pins sc_dma/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_MM2S] [get_bd_intf_pins sc_dma/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_S2MM] [get_bd_intf_pins sc_dma/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_dma/M00_AXI] [get_bd_intf_pins ps/S_AXI_HP1_FPD]

# CPU port streams (names from switch_top's point of view: cpu_s_axis flows INTO the switch)
make_bd_intf_pins_external -name cpu_s_axis [get_bd_intf_pins dma/M_AXIS_MM2S]
make_bd_intf_pins_external -name cpu_m_axis [get_bd_intf_pins dma/S_AXIS_S2MM]

# interrupts: 3x (mac interrupt + mac_irq) then DMA mm2s/s2mm
set k 0
foreach n {pl0_interrupt pl0_mac_irq pl1_interrupt pl1_mac_irq sfp_interrupt sfp_mac_irq} {
  create_bd_port -dir I $n
  connect_bd_net [get_bd_ports $n] [get_bd_pins irq/In$k]; incr k
}
connect_bd_net [get_bd_pins dma/mm2s_introut] [get_bd_pins irq/In6]
connect_bd_net [get_bd_pins dma/s2mm_introut] [get_bd_pins irq/In7]
connect_bd_net [get_bd_pins irq/dout] [get_bd_pins ps/pl_ps_irq0]

# PS GEM external-FIFO <-> switch_top GEM bridges (port names = kr260_pl_top's).
# The PS gives separate RX and TX FIFO clocks; the bridge takes both.
foreach g {0 1} {
  foreach d {rx tx} {
    create_bd_port -dir O -type clk gem${g}_${d}_clk
    connect_bd_net [get_bd_pins ps/fmio_gem${g}_fifo_${d}_clk_to_pl_bufg] [get_bd_ports gem${g}_${d}_clk]
  }
  # PS outputs -> switch inputs (BD output ports named like the switch's *_i inputs)
  foreach {s w} {rx_w_data 8 rx_w_wr 1 rx_w_sop 1 rx_w_eop 1 rx_w_err 1 rx_w_flush 1 rx_w_status 45 tx_r_rd 1 tx_r_status 4 dma_tx_end_tog 1} {
    set bp gem${g}_${s}_i
    if {$w > 1} { create_bd_port -dir O -from [expr {$w-1}] -to 0 $bp } else { create_bd_port -dir O $bp }
    connect_bd_net [get_bd_pins ps/emio_enet${g}_$s] [get_bd_ports $bp]
  }
  # switch outputs -> PS inputs
  foreach {s w} {rx_w_overflow 1 tx_r_data_rdy 1 tx_r_valid 1 tx_r_data 8 tx_r_sop 1 tx_r_eop 1 tx_r_err 1 tx_r_underflow 1 tx_r_flushed 1 tx_r_control 1 dma_tx_status_tog 1} {
    set bp gem${g}_${s}_o
    if {$w > 1} { create_bd_port -dir I -from [expr {$w-1}] -to 0 $bp } else { create_bd_port -dir I $bp }
    connect_bd_net [get_bd_ports $bp] [get_bd_pins ps/emio_enet${g}_$s]
  }
}

# match the RTL's actual interface subsets so the BD wrapper carries no dangling signals
foreach n {pl0_s_axi pl1_s_axi sfp_s_axi mdio0_s_axi mdio1_s_axi} {
  set_property CONFIG.PROTOCOL AXI4LITE [get_bd_intf_ports $n]
}
foreach n {m_axi_ing m_axi_egr m_axi_cpu} {
  set_property -dict [list CONFIG.DATA_WIDTH 128 CONFIG.HAS_LOCK 0 CONFIG.HAS_CACHE 0 CONFIG.HAS_PROT 0 CONFIG.HAS_QOS 0 CONFIG.HAS_REGION 0] [get_bd_intf_ports $n]
}
# Fixed register map (PS HPM0_LPD window). MAC blocks are 256 KiB (18-bit AXI-Lite).
foreach {seg off rng} {
  dma/S_AXI_LITE/Reg   0x80000000 64K
  mdio0_s_axi/Reg      0x80010000 64K
  mdio1_s_axi/Reg      0x80020000 64K
  pl0_s_axi/Reg        0x80040000 256K
  pl1_s_axi/Reg        0x80080000 256K
  sfp_s_axi/Reg        0x800C0000 256K
} {
  assign_bd_address -offset $off -range $rng -target_address_space [get_bd_addr_spaces ps/Data] [get_bd_addr_segs $seg]
}
assign_bd_address
validate_bd_design
save_bd_design
make_wrapper -files [get_files $proj/kr260_switch.srcs/sources_1/bd/system/system.bd] -top
add_files -norecurse $proj/kr260_switch.gen/sources_1/bd/system/hdl/system_wrapper.v
set_property top kr260_top [current_fileset]
update_compile_order -fileset sources_1
file mkdir $here/reports
set fh [open $here/reports/address_map.txt w]
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data]] {
  puts $fh "[get_property NAME $seg]  offset=[get_property OFFSET $seg]  range=[get_property RANGE $seg]"
}
foreach as {dma/Data_SG dma/Data_MM2S dma/Data_S2MM} {
  foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces $as]] {
    puts $fh "$as -> [get_property NAME $seg]  offset=[get_property OFFSET $seg]  range=[get_property RANGE $seg]"
  }
}
close $fh

# vendor IP output products (kept out of rtl/; regenerated every build)
foreach ip [get_ips] { puts "IP [get_property NAME $ip] locked=[get_property IS_LOCKED $ip]" }
generate_target all [get_ips -filter {SCOPE == ""}]
if {$stage eq "bd"} { return }
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {$stage eq "synth"} { return }
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
