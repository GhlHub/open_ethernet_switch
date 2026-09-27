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
# The rate converter must not add an unsynchronized receiver reset or a
# combinational CSR cone ahead of the MAC TX-enable synchronizer.
set cdc_file [open $reports/routed_cdc.rpt r]
set cdc_text [read $cdc_file]
close $cdc_file
if {[regexp -line {CDC-(7|10)[^\n]*(u_pl/u_rgmii[01]/u_rate/|u_bd/system_i/pl[01]/inst/u_mac/tx_enable_sync_reg)} $cdc_text]} {
    error "PL rate-control reset/TX-enable CDC regression; inspect routed_cdc.rpt"
}
puts "PASS: PL rate-control reset and TX-enable CDC structures"
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
set fabric_clock [get_clocks clk_out3_pl_eth_clk_gen_ip]
if {abs([get_property PERIOD $fabric_clock] - 8.0) > 0.001} {
    error "Fabric clock must be 125 MHz (8 ns)"
}
# The PHY-management extraction must retain one physical IOBUF and both
# marked reset-release synchronizer stages per MDIO catalog instance.
foreach i {0 1} {
    set pads [get_cells -hier -filter "REF_NAME == IOBUF && NAME =~ *mdio${i}*/inst/u_controller/u_iobuf_mdio"]
    if {[llength $pads] != 1} {error "Missing packaged MDIO${i} IOBUF"}
    set stages [get_cells -hier -filter "NAME =~ *mdio${i}*/inst/init_go_sync_reg* && ASYNC_REG == TRUE"]
    if {[llength $stages] != 2} {error "Missing packaged MDIO${i} reset-release synchronizer stages"}
}
puts "PASS: packaged MDIO IOBUFs and reset-release synchronizers"
puts "PASS: 125 MHz fabric clock"
puts "PASS: retained RGMII clock/instance constraints resolve"
} message options]} {
    puts stderr [dict get $options -errorinfo]
    exit 1
}
