# Sourced after opening a routed checkpoint, with report directory in $out.
# Audit every first-stage bit rather than sampling the worst paths globally.
# Check maximum flight time against one source period and the active timing
# constraint. This is a route coverage/bound check, not a metastability or
# complete bus-skew proof; launch-clock skew, single-step updates and reset
# remain part of the CDC contract.
set gray_report [open $out/custom_gray.tsv w]
puts $gray_report "source\tdestination\tmax_datapath_ns\tsource_period_ns\tconstraint_slack_ns"
foreach {pattern expected} {
 {*gray_sync1_reg*} 144
 {*mailboxes/activity_meta_reg*} 52
} {
 set destinations [get_cells -quiet -hier -filter "NAME =~ $pattern"]
 if {[llength $destinations] != $expected} {
  error "Gray crossing inventory changed: $pattern expected $expected bits, found [llength $destinations]; review before updating the inventory"
 }
 foreach destination $destinations {
  if {![get_property ASYNC_REG $destination]} {
   error "Missing ASYNC_REG on $destination"
  }
  set paths [get_timing_paths -to [get_pins $destination/D] -delay_type max -max_paths 1]
  if {[llength $paths] != 1} {error "Missing timed Gray bit: $destination"}
  set path [lindex $paths 0]
  set source [get_property STARTPOINT_PIN $path]
  # Gray MSB equals binary MSB; synthesis merges these six launch registers.
  set merged_msb [expr {
   [regexp {/(rx_desc_wr_gray_sync1_reg\[4\]|tx_desc_wr_gray_sync1_reg\[3\])$} $destination] &&
   $source eq "[string map {_gray_sync1_reg _bin_reg} $destination]/C"
  }]
  if {![regexp {(gray[^/]*_reg|activity_reg)\[} $source] && !$merged_msb} {
   error "Unexpected Gray launch register: $source -> $destination"
  }
  set clocks [get_clocks -of_objects [get_pins $source]]
  if {[llength $clocks] != 1} {error "Ambiguous Gray source clock: $source"}
  set period [get_property PERIOD $clocks]
  set delay [get_property DATAPATH_DELAY $path]
  set slack [get_property SLACK $path]
  if {![string is double -strict $slack] || ![string is double -strict $delay] ||
      ![string is double -strict $period]} {
   error "Missing timed Gray bit: $destination (no numeric delay, period or constraint slack)"
  }
  if {$delay < 0 || $delay >= $period || $slack < 0} {
   error "Gray physical bound failed: $source -> $destination, delay=$delay period=$period slack=$slack"
  }
  puts $gray_report "$source\t$destination/D\t$delay\t$period\t$slack"
 }
}
close $gray_report
puts "CUSTOM_GRAY_PASS: all 196 first-stage bits timed below one source period"
