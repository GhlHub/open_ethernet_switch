# Routed checks for the first partition, preserving the board physical shell.
# Optional arguments: routed checkpoint path, report output directory.
if {[catch {
set root [file dirname [file dirname [file normalize [info script]]]]
set checkpoint $root/build/vivado_kr260_modular/kr260_switch.runs/impl_1/kr260_top_routed.dcp
if {[llength $argv]} {set checkpoint [file normalize [lindex $argv 0]]}
set reports $root/build/ip_refactor
if {[llength $argv] > 1} {set reports [file normalize [lindex $argv 1]]}
file mkdir $reports
open_checkpoint $checkpoint
report_timing_summary -report_unconstrained -check_timing_verbose -file $reports/timing_summary.rpt
report_utilization -file $reports/utilization.rpt
report_cdc -details -file $reports/routed_cdc.rpt
report_clock_interaction -file $reports/clock_interaction.rpt
report_methodology -file $reports/methodology.rpt
report_drc -file $reports/drc.rpt
foreach cell {u_pl/u_rgmii0/u_oddre1_txc u_pl/u_rgmii1/u_oddre1_txc} {
    if {[llength [get_cells $cell]] != 1} {error "Missing forwarded-clock instance $cell"}
}
foreach clock {pl0_rgmii_txc_fwd pl1_rgmii_txc_fwd pl0_rgmii_rxc pl1_rgmii_rxc} {
    if {[llength [get_clocks $clock]] != 1} {error "Missing physical clock $clock"}
}
foreach pattern {clk_pl_0 clk_out3_pl_eth_clk_gen_ip clk_out1_pl_eth_clk_gen_ip
                 clk_out1_pl_eth_clk_gen_ip_1 clk_out1_sfp_pcs_clk_gen_ip*
                 clk_out2_sfp_pcs_clk_gen_ip* clk_gem0_rx_0 clk_gem0_tx_0
                 clk_gem1_rx_0 clk_gem1_tx_0} {
    if {![llength [get_clocks -quiet $pattern]]} {error "Missing constrained clock $pattern"}
}
puts "PASS: retained RGMII clock/instance constraints resolve"
} message options]} {
    puts stderr [dict get $options -errorinfo]
    exit 1
}
