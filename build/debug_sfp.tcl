# SFP investigation image, built from a linked synthesis checkpoint.
# Usage: vivado -mode batch -source build/debug_sfp.tcl -tclargs input.dcp
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set out $root/build/gem1_debug/sfp
file mkdir $out
set_param general.maxThreads 8
if {[llength $argv]!=1} {error "Provide a fully linked synthesis checkpoint with implementation constraints"}
open_checkpoint [lindex $argv 0]
proc net {name} {
    set n [get_nets -hier -filter "NAME == $name"]
    if {[llength $n] != 1} {error "Expected one net: $name (got $n)"}
    return $n
}
proc bus {name width} {
    set nets {}
    for {set i 0} {$i<$width} {incr i} {lappend nets [net [format {%s[%d]} $name $i]]}
    return $nets
}
proc ila {name clock depth probes} {
    create_debug_core $name ila
    set_property C_DATA_DEPTH $depth [get_debug_cores $name]
    set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores $name]
    set_property C_TRIGIN_EN false [get_debug_cores $name]
    set_property C_TRIGOUT_EN false [get_debug_cores $name]
    set_property C_ADV_TRIGGER false [get_debug_cores $name]
    connect_debug_port $name/clk $clock
    set index 0
    foreach nets $probes {
        if {$index} {create_debug_port $name probe}
        set_property port_width [llength $nets] [get_debug_ports $name/probe$index]
        connect_debug_port $name/probe$index $nets
        incr index
    }
}

set gt [get_cells -hier -filter {REF_NAME == GTHE4_CHANNEL}]
if {[llength $gt]!=1} {error "Expected one SFP GTH"}
proc gt_pin {port} {global gt; return [get_pins "[lindex $gt 0]/$port"]}
proc observed_pin {pin label} {
 set n [get_nets -of_objects $pin]
 if {![llength $n]} {
  set n [create_net $label]
  connect_net -net $n -objects $pin
 }
 return $n
}
proc gt_bus {port width} {
 set result {}
 for {set i 0} {$i<$width} {incr i} {
  lappend result [observed_pin [gt_pin [format {%s[%d]} $port $i]] debug_${port}_$i]
 }
 return $result
}
# The bring-up checkpoint predates the corrected RXCTRL wiring. Rebind the
# two known consumer registers to the documented decoded GTH outputs.
# This also works with newly synthesized corrected RTL (same final sources).
for {set i 0} {$i<2} {incr i} {
 foreach {reg port} {rx_k_q_reg RXCTRL0 rx_disperr_q_reg RXCTRL1} {
  set cell [get_cells -hier -filter [format {NAME =~ */u_pcs/%s[%d]} $reg $i]]
  if {[llength $cell]!=1} {error "Missing PCS consumer $reg bit $i"}
  set p [get_pins $cell/D]
  set old [get_nets -of_objects $p]
  disconnect_net -net $old -objects $p
  set n [observed_pin [gt_pin [format {%s[%d]} $port $i]] debug_${port}_$i]
  connect_net -hierarchical -net $n -objects $p
 }
}
# Clock/reset topology must come from the regenerated Wizard option-2 IP.
# Do not approximate the calibration/reset circuitry with netlist rewiring.
set txclock [get_nets -of_objects [gt_pin TXOUTCLK]]
set user_clock_loads [get_pins -leaf -of_objects [get_nets -segments $txclock] -filter {DIRECTION == IN && NAME =~ *userclk*}]
if {[llength $user_clock_loads] < 1} {
 error "Re-synthesize with ENABLE_COMMON_USRCLK=2 before inserting SFP ILAs"
}
set status {}
foreach p {GTPOWERGOOD CPLLLOCK CPLLREFCLKLOST TXRESETDONE RXRESETDONE TXPMARESETDONE RXPMARESETDONE RXBYTEISALIGNED RXCOMMADET GTRXRESET GTTXRESET} {
 lappend status [observed_pin [gt_pin $p] debug_$p]
}
set mmcm [get_cells -hier -filter {REF_NAME == MMCME4_ADV && NAME =~ *u_sfp_clkgen*}]
if {[llength $mmcm]!=1} {error "Missing SFP MMCM"}
set lock [observed_pin [get_pins $mmcm/LOCKED] debug_sfp_mmcm_lock]
lappend status $lock [net u_pl/gth_usrclk_rst_n]
foreach p {CPLLRESET CPLLPD TXUSERRDY RXUSERRDY} {
 lappend status [observed_pin [gt_pin $p] debug_$p]
}
lappend status [gt_bus TXOUTCLKSEL 3]
set calstate [lsort -dictionary [get_nets -quiet -hier -filter {NAME =~ *cpll_cal_tx_i/cpll_cal_state*}]]
if {[llength $calstate]} {lappend status $calstate}

# Slow snapshots of negotiation state; multi-bit values may straddle an
# update because this status ILA is in the independent 50 MHz domain.
set an u_pl/u_switch/u_sfp0/u_pcs/u_autoneg
lappend status [bus $an/state_q 3]
lappend status [list [net [format {%s/tx_config_q_reg_n_0_[5]} $an]] [net [format {%s/tx_config_q_reg_n_0_[14]} $an]]]
lappend status [bus $an/restart_cnt_q_reg_n_0_ 32]
lappend status [bus $an/link_timer_cnt_q_reg_n_0_ 32]
ila ila_sfp_status [net freerun_clk] 1024 $status
ila ila_sfp_data [net u_pl/gth_usrclk] 2048 [list  [bus u_pl/sfp_rxdata 16] [gt_bus RXCTRL0 2] [gt_bus RXCTRL1 2]  [gt_bus RXCTRL3 2] [gt_bus RXBUFSTATUS 3] [bus u_pl/sfp_txdata 16]  [gt_bus TXCTRL2 2] [gt_bus RXCTRL2 2]]
set_property C_CLK_INPUT_FREQ_HZ 50000000 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [net freerun_clk]
write_checkpoint -force $out/pre_debug.dcp
close_project
cd $out
open_checkpoint $out/pre_debug.dcp
opt_design
read_xdc $root/constraints/kr260_clocks.xdc
write_debug_probes -force $out/sfp.ltx
write_checkpoint -force $out/instrumented.dcp
place_design
phys_opt_design
route_design
write_checkpoint -force $out/routed_unchecked.dcp
set pl0_delays [get_cells -hier -filter {REF_NAME == IDELAYE3 && NAME =~ u_pl/u_rgmii0/*}]
set_property DELAY_VALUE 900 $pl0_delays
report_timing_summary -file $out/timing.rpt
report_drc -file $out/drc.rpt
foreach delay {max min} {
 set p [get_timing_paths -delay_type $delay -max_paths 1]
 if {![llength $p] || [get_property SLACK $p]<0} {error "Debug timing failed: $delay"}
}
write_checkpoint -force $out/routed.dcp
write_bitstream -force $out/sfp.bit
