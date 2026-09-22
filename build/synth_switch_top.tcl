# Out-of-context synthesis of the assembled digital switch (switch_top).
# Run from build/:  vivado -mode batch -source synth_switch_top.tcl -nolog -nojournal
# File list is shared with the simulation Makefile (see switch_top_files.f);
# paths are relative to this directory.
set part xck26-sfvc784-2LV-c
set here [file dirname [file normalize [info script]]]
create_project -in_memory -part $part
set fh [open $here/switch_top_files.f]
foreach f [split [read $fh] "\n"] {
  if {$f ne ""} { read_verilog -sv [file normalize $here/$f] }
}
close $fh
set stats_generics {}
foreach option {STATS_DDR STATS_DEBUG} {
  set value 0
  if {[info exists ::env($option)]} {set value $::env($option)}
  if {$value ni {0 1}} {error "$option must be 0 or 1"}
  lappend stats_generics "$option=$value"
}
synth_design -top switch_top -mode out_of_context -part $part -generic $stats_generics
file mkdir $here/reports
report_utilization -file $here/reports/switch_top_utilization.rpt
report_clocks       -file $here/reports/switch_top_clocks.rpt
report_cdc          -file $here/reports/switch_top_cdc.rpt
