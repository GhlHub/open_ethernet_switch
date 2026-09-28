# 10G MAC FIFO Gray pointers/data ownership plus registered status crossings.
# RX and TX are independent even though both nominally run at 156.25 MHz.
set sfp10g_clocks {}
foreach pin {u_pl/u_gth10g/u_gt/gtwiz_userclk_tx_usrclk2_out u_pl/u_gth10g/u_gt/gtwiz_userclk_rx_usrclk2_out} {
  set c [get_clocks -of_objects [get_pins $pin]]
  if {![llength $c]} {error "Missing 10G user clock on $pin"}
  if {[llength $c] != 1 || abs([get_property PERIOD $c]-6.4)>0.001} {
    error "10G user clock must be 156.25 MHz: $pin"
  }
  foreach clock $c {lappend sfp10g_clocks $clock}
}
set sfp10g_clocks [lsort -unique $sfp10g_clocks]
set sfp10g_peers [get_clocks {clk_pl_0 clk_pl_1 clk_out3_pl_eth_clk_gen_ip}]
foreach a $sfp10g_clocks {
  foreach b [concat $sfp10g_peers $sfp10g_clocks] {
    if {$a ne $b} {
      set_max_delay -datapath_only -from $a -to $b 6.400
      set_max_delay -datapath_only -from $b -to $a 6.400
    }
  }
}
set sfp10g_root [file dirname [file dirname [info script]]]
source $sfp10g_root/third_party/verilog-ethernet/lib/axis/syn/vivado/axis_async_fifo.tcl
source $sfp10g_root/third_party/verilog-ethernet/syn/vivado/eth_mac_fifo.tcl

# Do not silently accept an upstream hierarchy change that removes constraints.
set sfp10g_fifos [get_cells -hier -filter {(ORIG_REF_NAME == axis_async_fifo || REF_NAME == axis_async_fifo)}]
if {[llength $sfp10g_fifos] != 2} {error "Expected exactly two 10G MAC asynchronous FIFOs"}
foreach fifo $sfp10g_fifos {
  foreach pointer {rd_ptr_gray_sync1_reg_reg wr_ptr_commit_sync_reg_reg wr_ptr_update_sync1_reg_reg wr_ptr_update_ack_sync1_reg_reg} {
    set stages [get_cells -hier -filter "NAME =~ $fifo/${pointer}* && ASYNC_REG == TRUE"]
    if {![llength $stages]} {error "Missing constrained frame FIFO synchronizer: $fifo/$pointer"}
  }
}
puts "PASS: 10G user clocks, two constrained asynchronous FIFOs and Gray/commit handshake synchronizer stages"
