# Regenerate both K26 transceiver profiles and check every changed DRP field.
# vivado -mode batch -source scripts/check_sfp_dual_profiles.tcl -tclargs NEW_DIR
if {[catch {
set root [file dirname [file dirname [file normalize [info script]]]]
if {[llength $argv]!=1} {error "usage: check_sfp_dual_profiles.tcl NEW_DIR"}
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "Use a new profile-check directory"}
file mkdir $out
create_project dual_profiles $out/project -part xck26-sfvc784-2LV-c
set_property board_part xilinx.com:kr260_som:part0:2.0 [current_project]
file copy $root/rtl/sfp_pcs/ip/gth_sfp_ip.xci $out/gth_sfp_ip.xci
import_ip $out/gth_sfp_ip.xci
set_property -dict {CONFIG.TX_PLL_TYPE QPLL1 CONFIG.RX_PLL_TYPE QPLL1} [get_ips gth_sfp_ip]
source $root/rtl/sfp_dual/ip/create_gth_dual.tcl
generate_target all [get_ips]
puts [exec python3 $root/scripts/generate_sfp_dual_drp.py --profiles $out/project/dual_profiles.gen --output $out/rom.sv]
set expected [open $root/rtl/sfp_dual/sfp_dual_drp_rom.sv r]
set actual [open $out/rom.sv r]
if {[read $expected] ne [read $actual]} {error "Checked-in DRP ROM differs from reviewed fields"}
close $expected
close $actual
close_project
puts "PASS: complete Wizard profile difference and masked DRP ROM audit"
} message options]} {
 puts stderr [dict get $options -errorinfo]
 exit 1
}
