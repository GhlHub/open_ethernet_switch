# Routed checks for the first partition, preserving the board physical shell.
# Optional argument: routed checkpoint path.
if {[catch {
set root [file dirname [file dirname [file normalize [info script]]]]
set checkpoint $root/build/vivado_kr260_modular/kr260_switch.runs/impl_1/kr260_top_routed.dcp
if {[llength $argv]} {set checkpoint [file normalize [lindex $argv 0]]}
set reports $root/build/ip_refactor
file mkdir $reports
open_checkpoint $checkpoint
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
puts "PASS: retained RGMII clock/instance constraints resolve"
} message options]} {
    puts stderr [dict get $options -errorinfo]
    exit 1
}
