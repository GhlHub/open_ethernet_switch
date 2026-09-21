# Run after boot_jtag.tcl has loaded the debug bitstream and halted R5.
# Arms both domains, starts R5, then exports the first transmit attempt.
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set out $root/build/gem1_debug
open_hw_manager
connect_hw_server -url 10.0.1.109:3121
set target [lindex [get_hw_targets] 0]
current_hw_target $target
set previous_frequency [get_property PARAM.FREQUENCY $target]
set_property PARAM.FREQUENCY 1000000 $target
open_hw_target
set dev [lindex [get_hw_devices -filter {PART =~ "xck26*" || PART =~ "xczu*"}] 0]
if {$dev eq ""} {error "KR260 PL device not found: [get_hw_devices]"}
current_hw_device $dev
set_property PROBES.FILE $out/kr260_gem1.ltx $dev
refresh_hw_device $dev
set gem [get_hw_ilas -of_objects $dev -filter {CELL_NAME == "ila_gem1_tx"}]
set feed [get_hw_ilas -of_objects $dev -filter {CELL_NAME == "ila_gem1_feed"}]
if {[llength $gem]!=1 || [llength $feed]!=1} {error "Expected both GEM1 ILAs: [get_hw_ilas]"}
foreach core [list $gem $feed] {
    set_property CONTROL.TRIGGER_POSITION 128 $core
    set_property CONTROL.TRIGGER_CONDITION AND $core
}
# Trigger GEM capture on SOP and fabric capture on an accepted FIFO write.
set sop [get_hw_probes -of_objects $gem -filter {NAME =~ "*gem1_tx_r_sop_o*"}]
set wr [get_hw_probes -of_objects $feed -filter {NAME =~ "*/wr_en"}]
if {[llength $sop]!=1 || [llength $wr]!=1} {error "Missing trigger probes: sop=$sop wr=$wr"}
set_property TRIGGER_COMPARE_VALUE eq1'b1 $sop
set_property TRIGGER_COMPARE_VALUE eq1'b1 $wr
run_hw_ila $feed
run_hw_ila $gem
puts "ILAS_ARMED"
set f [open $out/continue_r5.tcl w]
puts $f {connect -url tcp:10.0.1.109:3121}
puts $f {targets -set -filter {name =~ "Cortex-R5 #0"}}
puts $f {con}
puts $f {exit}
close $f
exec /tools/Xilinx/2026.1/Vitis/bin/xsdb $out/continue_r5.tcl
# Timeout is in minutes; a missing packet must not hang the capture forever.
wait_on_hw_ila -timeout 0.75 [list $gem $feed]
foreach {name core} [list gem $gem feed $feed] {
    set data [upload_hw_ila_data $core]
    write_hw_ila_data -force -csv_file $out/${name}.csv $data
    write_hw_ila_data -force $out/${name}.ila $data
}
set_property PARAM.FREQUENCY $previous_frequency $target
close_hw_manager
