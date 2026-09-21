# Export the existing project without rebuilding or resetting implementation.
set root [file normalize [file join [file dirname [info script]] ../..]]
open_project [file join $root build/vivado_kr260/kr260_switch.xpr]
write_hw_platform -fixed -force -file [file join $root build/r5/kr260_switch.xsa]
close_project
