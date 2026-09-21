# Add ILAs to an existing synthesized design and implement a separate debug image.
# Run from repository root: vivado -mode batch -source build/debug_gem1.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
cd $root
set out $root/build/gem1_debug
file mkdir $out
set_param general.maxThreads 8
if {[llength $argv]} {
    # Optional fully linked synthesis checkpoint with implementation XDCs.
    open_checkpoint [lindex $argv 0]
} else {
    open_project build/vivado_kr260/kr260_switch.xpr
    open_run synth_1
    foreach f {kr260_clocks.xdc kr260_rgmii_io.xdc} {read_xdc constraints/$f}
}
proc net {name} {
    set n [get_nets -hier -filter "NAME == $name"]
    if {[llength $n] != 1} {error "Expected one net: $name (got $n)"}
    return $n
}
proc bus {name width} {
    set nets {}
    for {set i 0} {$i<$width} {incr i} {lappend nets [net [format {%s[%d]} $name $i]]}
    return $nets
}
proc ila {name clock depth probes} {
    create_debug_core $name ila
    set_property C_DATA_DEPTH $depth [get_debug_cores $name]
    set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores $name]
    set_property C_TRIGIN_EN false [get_debug_cores $name]
    set_property C_TRIGOUT_EN false [get_debug_cores $name]
    set_property C_ADV_TRIGGER false [get_debug_cores $name]
    connect_debug_port $name/clk $clock
    set index 0
    foreach nets $probes {
        if {$index} {create_debug_port $name probe}
        set_property port_width [llength $nets] [get_debug_ports $name/probe$index]
        connect_debug_port $name/probe$index $nets
        incr index
    }
}
# Previously unused GEM status bits have no fanout. Attach probes directly to
# their PS8 output pins; this adds observation only, not functional logic.
set ps [get_cells -hier -filter {REF_NAME == PS8}]
set status {}
for {set i 0} {$i<4} {incr i} {
    set p [get_pins [format {%s/EMIOENET1TXRSTATUS[%d]} $ps $i]]
    if {[llength $p] != 1} {error "Missing GEM1 TX status pin $i"}
    set n [get_nets -of_objects $p]
    if {![llength $n]} {
        set n [create_net debug_gem1_status_$i]
        connect_net -net $n -objects $p
    }
    lappend status $n
}
set tx u_pl/u_switch/u_ps_gem1/u_tx
set gem_probes {}
foreach n {gem1_tx_r_rd_i gem1_tx_r_valid_o gem1_tx_r_sop_o gem1_tx_r_eop_o gem1_tx_r_data_rdy_o gem1_tx_r_underflow_o gem1_tx_r_flushed_o gem1_dma_tx_end_tog_i gem1_dma_tx_status_tog_o} {
    lappend gem_probes [net $n]
}
lappend gem_probes [bus gem1_tx_r_data_o 8] $status
lappend gem_probes [net $tx/u_fifo/xempty] [net $tx/hi_pending_q] [net $tx/sop_q_reg_n_0]
lappend gem_probes [bus $tx/u_fifo/fifo_rd_data 18]
lappend gem_probes [net $tx/u_fifo/rd_rst_busy] [net $tx/read_pending_q]
ila ila_gem1_tx [net gem1_tx_clk] 8192 $gem_probes
set fifo $tx/u_fifo/u_xpm_fifo
ila ila_gem1_feed [net $tx/clk_out3] 2048 [list [bus $fifo/din 18] [net $fifo/wr_en] [net $tx/full]]
set_property C_CLK_INPUT_FREQ_HZ 50000000 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [net freerun_clk]
write_checkpoint -force $out/pre_debug.dcp
close_project
cd $out
open_checkpoint $out/pre_debug.dcp
opt_design
write_debug_probes -force $out/kr260_gem1.ltx
write_checkpoint -force $out/instrumented.dcp
place_design
phys_opt_design
route_design
# ILA placement lengthens the PL0 RX clock path. Increase the existing fixed
# data/control input delays for this debug image only; no timing exceptions.
# The board RTL default stays at 700 ps. Both setup and hold are checked below.
set pl0_delays [get_cells -hier -filter {REF_NAME == IDELAYE3 && NAME =~ u_pl/u_rgmii0/*}]
if {[llength $pl0_delays] != 5} {error "Expected five PL0 RX IDELAYE3 cells"}
set_property DELAY_VALUE 900 $pl0_delays
report_timing_summary -file $out/timing.rpt
report_drc -file $out/drc.rpt
report_utilization -file $out/utilization.rpt
foreach delay {max min} {
    set path [get_timing_paths -delay_type $delay -max_paths 1]
    if {![llength $path] || [get_property SLACK $path] < 0} {
        error "Debug image fails $delay timing; inspect $out/timing.rpt"
    }
}
write_checkpoint -force $out/routed.dcp
write_bitstream -force $out/kr260_gem1.bit
puts "GEM1_DEBUG_IMAGE_COMPLETE"
