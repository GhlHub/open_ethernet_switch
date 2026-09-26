# Read-only routed audit; does not alter constraints or create CDC waivers.
# Usage: vivado -mode batch -source ip_repo/review_timing_cdc.tcl \
#          -tclargs <routed.dcp> <report-directory>
if {[catch {
if {[llength $argv] != 2} {error "Expected routed checkpoint and report directory"}
set checkpoint [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
file mkdir $out
open_checkpoint $checkpoint
report_timing_summary -report_unconstrained -check_timing_verbose -file $out/timing_summary.rpt
report_cdc -details -file $out/cdc.rpt
report_methodology -file $out/methodology.rpt
report_clock_interaction -file $out/clock_interaction.rpt
report_exceptions -coverage -file $out/exceptions_coverage.rpt
report_exceptions -ignored -file $out/exceptions_ignored.rpt
report_bus_skew -file $out/bus_skew.rpt
foreach port {pl0 pl1} {
 report_timing -from [get_clocks clk_out1_pl_eth_clk_gen_ip*] -to [get_ports ${port}_rgmii_tx*] -delay_type min_max -max_paths 20 -path_type full_clock_expanded -file $out/${port}_tx.rpt
 report_timing -from [get_ports ${port}_rgmii_rx*] -delay_type min_max -max_paths 20 -path_type full_clock_expanded -file $out/${port}_rx.rpt
}
set f [open $out/custom_crossings.tsv w]
puts $f "source\tdestination\tmax_datapath_ns\tslack_ns"
foreach pair {
 {*management/inst/regs/stats_index_reg* *req_sync_reg*}
 {*management/inst/regs/stats_index_reg* *count_reg*}
 {*value_q_reg* *value_sync1_reg*}
 {*value_reg* *management/inst/regs/s_axi_rdata_reg*}
 {*gray*_reg* *gray_sync1_reg*}
} {
 set from [get_cells -quiet -hier -filter "NAME =~ [lindex $pair 0]"]
 set to [get_cells -quiet -hier -filter "NAME =~ [lindex $pair 1]"]
 if {![llength $from] || ![llength $to]} {
  if {[lindex $pair 0] eq "*value_q_reg*" &&
      [llength [get_cells -quiet -hier -filter {NAME =~ *u_cpu_tx_framer/*}]]} {
   puts $f "RETIRED\tCPU override replaced by per-frame stream metadata"
   continue
  }
  error "Missing crossing family: $pair"
 }
 foreach p [get_timing_paths -from $from -to $to -max_paths 10000 -nworst 1] {
  puts $f "[get_property STARTPOINT_PIN $p]\t[get_property ENDPOINT_PIN $p]\t[get_property DATAPATH_DELAY $p]\t[get_property SLACK $p]"
 }
}
close $f
puts "REVIEW_COMPLETE: reports generated; this is not CDC sign-off"
} message options]} {
 puts stderr [dict get $options -errorinfo]
 exit 1
}
exit
