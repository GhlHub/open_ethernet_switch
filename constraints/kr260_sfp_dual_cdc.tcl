# Runtime GT configuration is not represented by static primitive attributes.
# Model both legal modes explicitly. They are physically exclusive; the mode
# controller changes the mux/divider only while GT and digital paths are reset.
set dual u_pl/u_gthdual
# Keep the two cascaded muxes in the CMT row beside GTH X0Y6. Delay grouping
# alone can choose distant BUFGCTRL sites, whose input routes differ by >1 ns.
set_property LOC BUFGCTRL_X0Y8 [get_cells $dual/rxselect]
set_property LOC BUFGCTRL_X0Y9 [get_cells $dual/rxselect2]
# Balance the related user-clock trees through both buffer levels. Without
# explicit grouping the small RXUSRCLK tree can take a substantially shorter
# route than RXUSRCLK2, violating the transceiver's maximum-skew requirement.
foreach {group pins} {
 sfp_dual_tx {txfast/O txslow/O}
 sfp_dual_rx {rxfast/O rxslow/O}
 sfp_dual_rx_mux {rxselect/O rxselect2/O}
} {
 foreach pin $pins {
  set_property CLOCK_DELAY_GROUP $group [get_nets -of_objects [get_pins $dual/$pin]]
 }
}
# This image's clock placement needs 200 ps additional PL0 receive data
# delay. This programs the five IDELAYE3 cells; it does not relax I/O timing.
set pl0_delays [get_cells -hier -filter {REF_NAME == IDELAYE3 && NAME =~ u_pl/u_rgmii0/*}]
if {[llength $pl0_delays]!=5} {error "Expected five PL0 receive data delays"}
set_property DELAY_VALUE 900 $pl0_delays
foreach direction {tx rx} {
 set source [get_pins $dual/u_gt/${direction}outclk_out]
 if {[llength $source]!=1} {error "Missing dual-rate GT $direction source"}
 create_clock -name sfp_dual_${direction}_source_10g -period 3.200 $source
 create_clock -add -name sfp_dual_${direction}_source_1g -period 16.000 $source
 foreach {suffix divide mode} {fast 1 10g fast 1 1g slow 2 10g slow 1 1g} {
  create_generated_clock -add -name sfp_dual_${direction}_${suffix}_${mode} \
   -source $source -master_clock sfp_dual_${direction}_source_${mode} \
   -divide_by $divide [get_pins $dual/${direction}${suffix}/O]
 }
}
# The 1G PCS MMCM is enabled only in 1G mode. Override automatic derivation
# from the 10G input frequency, which is never a running state for that MMCM.
set_clock_sense -stop_propagation -clocks [get_clocks sfp_dual_tx_slow_10g] [get_pins $dual/u_1g_clocks/u_mmcm/inst/mmcme4_adv_inst/CLKIN1]
foreach {port multiply name} {CLKOUT0 2 gmii CLKOUT1 1 pcs1g} {
 create_generated_clock -add -name sfp_dual_${name} \
  -source [get_pins $dual/u_gt/txoutclk_out] -master_clock sfp_dual_tx_source_1g \
  -multiply_by $multiply [get_pins $dual/u_1g_clocks/u_mmcm/inst/mmcme4_adv_inst/$port]
}
set one [get_clocks {sfp_dual_*_1g sfp_dual_gmii sfp_dual_pcs1g}]
set ten [get_clocks sfp_dual_*_10g]
set_clock_groups -physically_exclusive -group $one -group $ten
# 1G RX clocks from local TX via the elastic buffer. The recovered 1G clocks
# cannot propagate through the RX user-clock mux in that mode.
set_clock_sense -stop_propagation -clocks [get_clocks sfp_dual_rx_fast_1g] [get_pins $dual/rxselect/I1]
set_clock_sense -stop_propagation -clocks [get_clocks sfp_dual_rx_slow_1g] [get_pins $dual/rxselect2/I1]
set_clock_sense -stop_propagation -clocks [get_clocks sfp_dual_tx_fast_10g] [get_pins $dual/rxselect/I0]
set_clock_sense -stop_propagation -clocks [get_clocks sfp_dual_tx_slow_10g] [get_pins $dual/rxselect2/I0]
set peers [get_clocks {clk_pl_0 clk_pl_1 clk_out3_pl_eth_clk_gen_ip}]
# Runtime request/retry and ready/error status cross between the always-on
# GT controller and fabric/AXI domains through ASYNC_REG synchronizers.
foreach peer [get_clocks {clk_pl_0 clk_out3_pl_eth_clk_gen_ip}] {
 set_max_delay -datapath_only -from [get_clocks clk_pl_1] -to $peer 7.0
 set_max_delay -datapath_only -from $peer -to [get_clocks clk_pl_1] 7.0
}
foreach a [concat $one $ten] {
 foreach b $peers {
  set_max_delay -datapath_only -from $a -to $b 6.4
  set_max_delay -datapath_only -from $b -to $a 6.4
 }
}
# 10G TX and recovered RX are independent. 1G MMCM clocks stay related.
foreach a [get_clocks {sfp_dual_tx_fast_10g sfp_dual_tx_slow_10g}] {
 foreach b [get_clocks {sfp_dual_rx_fast_10g sfp_dual_rx_slow_10g}] {
  set_max_delay -datapath_only -from $a -to $b 6.4
  set_max_delay -datapath_only -from $b -to $a 6.4
 }
}
set root [file dirname [file dirname [info script]]]
source $root/third_party/verilog-ethernet/lib/axis/syn/vivado/axis_async_fifo.tcl
source $root/third_party/verilog-ethernet/syn/vivado/eth_mac_fifo.tcl
set fifos [get_cells -hier -filter {(ORIG_REF_NAME == axis_async_fifo || REF_NAME == axis_async_fifo)}]
if {[llength $fifos]!=2} {error "Expected two dual-port 10G asynchronous FIFOs"}
foreach fifo $fifos {
 foreach pointer {rd_ptr_gray_sync1_reg_reg wr_ptr_commit_sync_reg_reg wr_ptr_update_sync1_reg_reg wr_ptr_update_ack_sync1_reg_reg} {
  if {![llength [get_cells -hier -filter "NAME =~ $fifo/${pointer}* && ASYNC_REG == TRUE"]]} {
   error "Missing constrained frame FIFO synchronizer: $fifo/$pointer"
  }
 }
}
puts "PASS: dual-rate mode clocks and FIFO CDC constraints loaded"
