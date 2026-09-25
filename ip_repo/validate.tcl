# Validate all catalog cores in IP Integrator, including each physical stream
# connection. A separate project leaves the board's known-working build intact.
if {[catch {
set root [file dirname [file dirname [file normalize [info script]]]]
set catalog [file normalize [expr {[llength $argv] ? [lindex $argv 0] : "$root/build/ip_catalog"}]]
create_project -in_memory -part xck26-sfvc784-2LV-c
set_property ip_repo_paths [list $catalog] [current_project]
update_ip_catalog
file delete -force $root/build/ip_refactor/partition_validation
create_bd_design partition_validation -dir $root/build/ip_refactor
foreach {cell type} {fabric switch_fabric gem0 gem_port gem1 gem_port pl0 pl_port pl1 pl_port sfp sfp_port management management} {
    create_bd_cell -type ip -vlnv ghlhub.org:ethernet:$type:1.0 $cell
}
# Match the all-counter equivalence fixture; this is a validation design,
# not the board address/clock assembly.
set_property -dict {CONFIG.STATS_DDR 1 CONFIG.STATS_DEBUG 1 CONFIG.AGE_TICK_DIVIDE_COUNT 100} [get_bd_cells fabric]
set_property -dict {CONFIG.STATS_DDR 1 CONFIG.STATS_DEBUG 1} [get_bd_cells management]
set i 0
foreach cell {gem0 gem1 pl0 pl1 sfp} {
    connect_bd_intf_net [get_bd_intf_pins $cell/m_axis] [get_bd_intf_pins [format "fabric/s%02d_axis" $i]]
    connect_bd_intf_net [get_bd_intf_pins $cell/s_axis] [get_bd_intf_pins [format "fabric/m%02d_axis" $i]]
    incr i
}
# One fabric clock/reset; MAC control and physical clocks stay independent.
set fabric_clk [create_bd_port -dir I -type clk -freq_hz 100000000 fabric_clk]
set fabric_reset [create_bd_port -dir I -type rst fabric_reset_n]
set_property CONFIG.POLARITY ACTIVE_LOW $fabric_reset
foreach cell {fabric gem0 gem1 pl0 pl1 sfp} {
    connect_bd_net $fabric_clk [get_bd_pins $cell/clk]
    connect_bd_net $fabric_reset [get_bd_pins $cell/rst_n]
}
foreach cell [get_bd_cells] {
    foreach bus [get_bd_intf_pins -of_objects $cell] {
        if {![llength [get_bd_intf_nets -quiet -of_objects $bus]]} {make_bd_intf_pins_external $bus}
    }
    foreach pin [get_bd_pins -of_objects $cell -filter {TYPE == clk || TYPE == rst}] {
        if {![llength [get_bd_nets -quiet -of_objects $pin]]} {
            make_bd_pins_external $pin
            set ports [get_bd_ports -of_objects [get_bd_nets -of_objects $pin]]
            if {[get_property TYPE $pin] eq "clk"} {
                # Reference-design frequencies, not restrictions on the IP.
                set hz 125000000
                if {[string match *axis_clk $pin] || [string match /management/clk $pin]} {set hz 142857143}
                if {[string match *gth_clk $pin]} {set hz 62500000}
                set_property CONFIG.FREQ_HZ $hz $ports
            }
        }
    }
    foreach pin [get_bd_pins -of_objects $cell] {
        # Interface members must remain driven by the interface connection.
        # A scalar get_bd_nets query does not expose that connection before
        # generation; externalizing those pins would silently override it.
        set member 0
        foreach bus [get_bd_intf_pins -of_objects $cell] {
            if {[string match "[file tail $bus]_*" [file tail $pin]]} {set member 1}
        }
        if {$member} {continue}
        if {![llength [get_bd_nets -quiet -of_objects $pin]]} {make_bd_pins_external $pin}
    }
}
assign_bd_address
validate_bd_design
save_bd_design
generate_target all [get_files partition_validation.bd]
make_wrapper -files [get_files partition_validation.bd] -top
puts "PASS: all five IP types validate and generate in IP Integrator"
} message options]} {
    puts stderr [dict get $options -errorinfo]
    exit 1
}
