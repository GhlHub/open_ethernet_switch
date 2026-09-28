# Continue the already generated and simulation-validated acceptance project.
if {[catch {
    if {[llength $argv] != 1} {error "usage: implement.tcl project.xpr"}
    open_project [file normalize [lindex $argv 0]]
    set root [file dirname [file dirname [file normalize [info script]]]]
    if {"KR260_SFP_DUAL" in [get_property verilog_define [current_fileset]]} {
        set_property STEPS.OPT_DESIGN.TCL.PRE $root/constraints/kr260_sfp_dual_cdc.tcl [get_runs impl_1]
    } elseif {"KR260_SFP_10G" in [get_property verilog_define [current_fileset]]} {
        set_property STEPS.OPT_DESIGN.TCL.PRE $root/constraints/kr260_sfp_10g_cdc.tcl [get_runs impl_1]
    }
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        launch_runs synth_1 -jobs 8
        wait_on_run synth_1
    }
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"
    }
    if {[string match -nocase *error* [get_property STATUS [get_runs impl_1]]]} {
        reset_run impl_1
    }
    launch_runs impl_1 -to_step write_bitstream -jobs 8
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        error "Implementation failed: [get_property STATUS [get_runs impl_1]]"
    }
    close_project
} message options]} {
    puts stderr [dict get $options -errorinfo]
    exit 1
}
