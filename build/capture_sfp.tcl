# Snapshot a running SFP debug image; no processor reset or halt.
set root [file normalize [file join [file dirname [info script]] ..]]
set out $root/build/gem1_debug/sfp
open_hw_manager
connect_hw_server -url 10.0.1.109:3121
set target [lindex [get_hw_targets] 0]
current_hw_target $target
set saved_frequency [get_property PARAM.FREQUENCY $target]
set_property PARAM.FREQUENCY 1000000 $target
try {
 open_hw_target
 set dev [lindex [get_hw_devices -filter {PART =~ "xck26*"}] 0]
 current_hw_device $dev
 set_property PROBES.FILE $out/sfp.ltx $dev
 refresh_hw_device $dev
 foreach name {ila_sfp_status ila_sfp_data} {
  set core [get_hw_ilas -of_objects $dev -filter "CELL_NAME == $name"]
  if {[llength $core]!=1} {error "Missing $name"}
  if {[catch {
   run_hw_ila -trigger_now $core
   wait_on_hw_ila -timeout 0.1 $core
   set data [upload_hw_ila_data $core]
   write_hw_ila_data -force -csv_file $out/$name.csv $data
   write_hw_ila_data -force $out/$name.ila $data
  } message]} {puts "CAPTURE_FAILED $name: $message"}
 }
} finally {
 set_property PARAM.FREQUENCY $saved_frequency $target
 close_hw_manager
}
