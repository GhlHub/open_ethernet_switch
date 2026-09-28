# Actual GTHE4 simulation, including masked DRP and both serial protocols.
# vivado -mode batch -source scripts/simulate_sfp_dual_gth.tcl -tclargs NEW_DIR
set root [file dirname [file dirname [file normalize [info script]]]]
if {[llength $argv]!=1} {error "usage: simulate_sfp_dual_gth.tcl NEW_DIR"}
set out [file normalize [lindex $argv 0]]
if {[file exists $out]} {error "Use a new simulation directory"}
file mkdir $out
create_project dual_gt_sim $out/project -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kr260_som:part0:2.0 [current_project]
set_property target_language Verilog [current_project]
source $root/rtl/sfp_dual/ip/create_gth_dual.tcl
file copy -force $root/rtl/sfp_pcs/ip/sfp_pcs_clk_gen_ip.xci $out/sfp_pcs_clk_gen_ip.xci
import_ip $out/sfp_pcs_clk_gen_ip.xci
generate_target all [get_ips]
add_files [list $root/rtl/common/rst_sync.sv $root/rtl/sfp_pcs/sfp_pcs_clk_gen.sv $root/rtl/sfp_dual/gth_sfp_dual_wrapper.sv $root/rtl/sfp_dual/sfp_dual_reconfigure.sv $root/rtl/sfp_dual/sfp_dual_drp_rom.sv]
add_files -fileset sim_1 $root/tb/tb_sfp_dual_gth.sv
set_property top tb_sfp_dual_gth [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
launch_simulation
run all
close_sim
close_project
set log [open $out/project/dual_gt_sim.sim/sim_1/behav/xsim/simulate.log r]
set result [read $log]
close $log
if {![string match {*PASS: GTHE4*} $result] || [regexp {Fatal:|FATAL:|ERROR:} $result]} {error "GTHE4 simulation did not pass; inspect simulate.log"}
puts "PASS: actual GTHE4 model simulation"
