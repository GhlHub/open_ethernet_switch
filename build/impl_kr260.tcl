# Implementation (place/route/bitstream) of the project created by
# build_kr260.tcl (run that with the "synth" stage first). Reports go to
# build/reports/.  vivado -mode batch -source impl_kr260.tcl -nolog -nojournal
set here [file dirname [file normalize [info script]]]
open_project $here/vivado_kr260/kr260_switch.xpr
# pick up any constraint files added since the project was created
foreach x [glob $here/../constraints/*.xdc] {
  if {[llength [get_files -quiet $x]] == 0} { add_files -fileset constrs_1 -norecurse $x }
}
set_property USED_IN {implementation} [get_files $here/../constraints/kr260_clocks.xdc]
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
file mkdir $here/reports
report_timing_summary -file $here/reports/impl_timing_summary.rpt
report_utilization    -file $here/reports/impl_utilization.rpt
report_clock_interaction -file $here/reports/impl_clock_interaction.rpt
report_cdc            -file $here/reports/impl_cdc.rpt
report_cdc -summary   -file $here/reports/impl_cdc_summary.rpt
report_drc            -file $here/reports/impl_drc.rpt
report_methodology    -file $here/reports/impl_methodology.rpt
report_io             -file $here/reports/impl_io.rpt
