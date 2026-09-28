# Routed checks for the first partition, preserving the board physical shell.
# Optional arguments: routed checkpoint path, report output directory.
if {[catch {
set root [file dirname [file dirname [file normalize [info script]]]]
set checkpoint $root/build/vivado_kr260_modular/kr260_switch.runs/impl_1/kr260_top_routed.dcp
if {[llength $argv]} {set checkpoint [file normalize [lindex $argv 0]]}
set reports $root/build/ip_refactor
if {[llength $argv] > 1} {set reports [file normalize [lindex $argv 1]]}
file mkdir $reports
open_checkpoint $checkpoint
report_timing_summary -report_unconstrained -check_timing_verbose -file $reports/timing_summary.rpt
# Pulse-width checks also include the GT RXUSRCLK/RXUSRCLK2 maximum skew.
# Setup/hold acceptance alone must not overlook that physical requirement.
set timing_file [open $reports/timing_summary.rpt r]
set timing_text [read $timing_file]
close $timing_file
if {![regexp -line {^\s*(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+[0-9]+\s+[0-9]+\s+(-?[0-9]+\.[0-9]+)\s+(-?[0-9]+\.[0-9]+)\s+[0-9]+\s+[0-9]+\s+(-?[0-9]+\.[0-9]+)\s+} $timing_text row wns tns whs ths wpws]} {
    error "Missing complete setup/hold/pulse-width summary"
}
set pulse_width_slack $wpws
report_utilization -file $reports/utilization.rpt
report_cdc -details -file $reports/routed_cdc.rpt
# The rate converter must not add an unsynchronized receiver reset or a
# combinational CSR cone ahead of the MAC TX-enable synchronizer.
set cdc_file [open $reports/routed_cdc.rpt r]
set cdc_text [read $cdc_file]
close $cdc_file
if {[regexp -line {CDC-(7|10)[^\n]*(u_pl/u_rgmii[01]/u_rate/|u_bd/system_i/pl[01]/inst/u_mac/tx_enable_sync_reg)} $cdc_text]} {
    error "PL rate-control reset/TX-enable CDC regression; inspect routed_cdc.rpt"
}
puts "PASS: PL rate-control reset and TX-enable CDC structures"
if {[regexp -line {CDC-10[^\n]*u_bd/system_i/sfp/inst/fault_control/} $cdc_text]} {
    error "10G fault status must be registered before crossing clock domains"
}
report_clock_interaction -file $reports/clock_interaction.rpt
report_methodology -file $reports/methodology.rpt
report_drc -file $reports/drc.rpt
foreach cell {u_pl/u_rgmii0/u_oddre1_txc u_pl/u_rgmii1/u_oddre1_txc} {
    if {[llength [get_cells $cell]] != 1} {error "Missing forwarded-clock instance $cell"}
}
foreach clock {pl0_rgmii_txc_fwd pl1_rgmii_txc_fwd pl0_rgmii_rxc pl1_rgmii_rxc} {
    if {[llength [get_clocks $clock]] != 1} {error "Missing physical clock $clock"}
}
set required_clocks {clk_pl_0 clk_out3_pl_eth_clk_gen_ip clk_out1_pl_eth_clk_gen_ip
                     clk_out1_pl_eth_clk_gen_ip_1 clk_gem0_rx_0 clk_gem0_tx_0
                     clk_gem1_rx_0 clk_gem1_tx_0}
if {[llength [get_cells -quiet u_pl/u_gthdual]]} {
    if {[regexp -line {CDC-10[^\n]*u_bd/system_i/sfp/inst/(pcs_meta|status_meta)_reg} $cdc_text]} {
        error "Dual-port status must be registered before crossing clock domains"
    }
    if {[llength [get_cells -hier -filter {REF_NAME == GTHE4_CHANNEL}]]!=1} {error "Dual mode requires exactly one physical GTH channel"}
    foreach {name period} {sfp_dual_tx_slow_10g 6.4 sfp_dual_rx_slow_10g 6.4 sfp_dual_tx_slow_1g 16.0 sfp_dual_gmii 8.0 sfp_dual_pcs1g 16.0} {
        set c [get_clocks $name]
        if {[llength $c]!=1 || abs([get_property PERIOD $c]-$period)>0.001} {error "Missing/incorrect dual-mode clock $name"}
    }
    foreach {pin expected} {
        txslow/O {sfp_dual_tx_slow_1g sfp_dual_tx_slow_10g}
        rxselect2/O {sfp_dual_tx_slow_1g sfp_dual_rx_slow_10g}
        u_1g_clocks/u_mmcm/inst/mmcme4_adv_inst/CLKOUT0 sfp_dual_gmii
        u_1g_clocks/u_mmcm/inst/mmcme4_adv_inst/CLKOUT1 sfp_dual_pcs1g
    } {
        set clocks [get_property NAME [get_clocks -of_objects [get_pins u_pl/u_gthdual/$pin]]]
        if {[lsort $clocks] ne [lsort $expected]} {error "Unexpected clocks at dual-mode $pin: $clocks"}
    }
    set skew_report [report_bus_skew -return_string -warn_on_violation]
    set skew_file [open $reports/bus_skew.rpt w]
    puts $skew_file $skew_report
    close $skew_file
    if {[regexp {Slack \(VIOLATED\)} $skew_report]} {error "Dual-mode FIFO bus-skew violation"}
    puts "PASS: one GTH channel, both runtime mode clocks and FIFO bus skew"
} elseif {[llength [get_cells -quiet u_pl/u_gth10g]]} {
    foreach direction {tx rx} {
        set c [get_clocks -of_objects [get_pins u_pl/u_gth10g/u_gt/gtwiz_userclk_${direction}_usrclk2_out]]
        if {[llength $c] != 1 || abs([get_property PERIOD $c]-6.4)>0.001} {
            error "10G $direction clock must be 156.25 MHz"
        }
    }
    puts "PASS: independent 156.25 MHz 10G TX/RX clocks"
    set skew_report [report_bus_skew -return_string -warn_on_violation]
    set skew_file [open $reports/bus_skew.rpt w]
    puts $skew_file $skew_report
    close $skew_file
    if {[regexp {Slack \(VIOLATED\)} $skew_report]} {
        error "Routed bus skew violation; see bus_skew.rpt"
    }
    puts "PASS: routed FIFO bus-skew constraints"

} else {
    lappend required_clocks clk_out1_sfp_pcs_clk_gen_ip* clk_out2_sfp_pcs_clk_gen_ip*
}
foreach pattern $required_clocks {
    if {![llength [get_clocks -quiet $pattern]]} {error "Missing constrained clock $pattern"}
}
set fabric_clock [get_clocks clk_out3_pl_eth_clk_gen_ip]
if {abs([get_property PERIOD $fabric_clock] - 8.0) > 0.001} {
    error "Fabric clock must be 125 MHz (8 ns)"
}
# The PHY-management extraction must retain one physical IOBUF and both
# marked reset-release synchronizer stages per MDIO catalog instance.
foreach i {0 1} {
    set pads [get_cells -hier -filter "REF_NAME == IOBUF && NAME =~ *mdio${i}*/inst/u_controller/u_iobuf_mdio"]
    if {[llength $pads] != 1} {error "Missing packaged MDIO${i} IOBUF"}
    set stages [get_cells -hier -filter "NAME =~ *mdio${i}*/inst/init_go_sync_reg* && ASYNC_REG == TRUE"]
    if {[llength $stages] != 2} {error "Missing packaged MDIO${i} reset-release synchronizer stages"}
}
puts "PASS: packaged MDIO IOBUFs and reset-release synchronizers"
puts "PASS: 125 MHz fabric clock"
puts "PASS: retained RGMII clock/instance constraints resolve"
# A generated bitstream alone is not timing acceptance.
if {$pulse_width_slack < 0.0} {error "Routed pulse-width/GT clock skew failed: $pulse_width_slack ns"}
foreach delay_type {max min} {
    set worst [get_timing_paths -quiet -delay_type $delay_type -max_paths 1]
    if {![llength $worst]} {error "No $delay_type timing path returned"}
    set slack [get_property SLACK $worst]
    if {$slack < 0.0} {error "Routed $delay_type timing failed: slack $slack ns; see timing_summary.rpt"}
    puts "PASS: routed $delay_type timing slack $slack ns"
}

} message options]} {
    puts stderr [dict get $options -errorinfo]
    exit 1
}
