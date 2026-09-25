# Volatile bring-up; resets the PS and replaces its current running session.
# Run: xsdb software/r5/boot_jtag.tcl [hw_server_url] [bitstream] [halt]
set root [file normalize [file join [file dirname [info script]] ../..]]
cd $root
set url [expr {[llength $argv] ? [lindex $argv 0] : "tcp:10.0.1.107:3121"}]
set fsbl build/r5/workspace/kr260_r5/zynqmp_fsbl/build/fsbl.elf
set init build/r5/workspace/kr260_r5/hw/sdt/psu_init.tcl
set bit build/vivado_kr260/kr260_switch.runs/impl_1/kr260_top.bit
if {[llength $argv] > 1} {set bit [lindex $argv 1]}
set halt [expr {[llength $argv] > 2 && [lindex $argv 2] eq "halt"}]
set elf software/r5/out/kr260_r5.elf
foreach f [list $fsbl $init $bit $elf] {
    if {![file isfile $f]} { error "Missing build output: $f" }
}
# XSDB's expression evaluator cannot resolve this assembly-only symbol from
# DWARF. Resolve its ELF symbol address explicitly instead.
set nm /tools/Xilinx/2026.1/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-nm
if {![regexp -line {^([0-9a-fA-F]+) [Tt] XFsbl_Exit$} [exec $nm $fsbl] -> exit_hex]} {
    error "FSBL has no XFsbl_Exit symbol"
}
set exit_addr [expr "0x$exit_hex"]
connect -url $url
targets -set -filter {name =~ "PSU"}
set boot [mrd -value 0xff5e0200]
set breakpoint ""
try {
    # Override boot to JTAG only for this system reset. A processor-only
    # reset is insufficient for reliable DDR reinitialization.
    mwr 0xff5e0200 0x100
    rst -system
    after 2000
    targets -set -filter {name =~ "Cortex-A53 #0"}
    catch {stop}
    rst -processor -clear-registers
    dow $fsbl
    set breakpoint [bpadd -addr $exit_addr -type hw]
    con -block -timeout 45
    bpremove $breakpoint
    set breakpoint ""
    targets -set -filter {name =~ "PSU"}
    set status [mrd -value 0xffd80060]
    if {$status != 0} {error [format "FSBL failed: status 0x%08x" $status]}
    puts "FSBL initialization complete"
} on error {message options} {
    targets -set -filter {name =~ "Cortex-A53 #0"}
    catch {stop}
    return -options $options $message
} finally {
    if {$breakpoint ne ""} {catch {bpremove $breakpoint}}
    targets -set -filter {name =~ "PSU"}
    mwr 0xff5e0200 $boot
}
# Both R5s and their AMBA interface must be reset while changing RPU mode.
set reset [mrd -value 0xff5e023c]
mwr 0xff5e023c [expr {$reset | 7}]
set mode [mrd -value 0xff9a0000]
mwr 0xff9a0000 [expr {($mode | 8) & ~0x50}]
foreach addr {0xff9a0100 0xff9a0200} {
    set value [mrd -value $addr]
    mwr $addr [expr {$value & ~1}]
}
set clk [mrd -value 0xff5e0090]
mwr 0xff5e0090 [expr {$clk | 0x1000000}]
mwr 0xff5e023c [expr {($reset | 2) & ~5}]
after 200
# PS TAP owns the programmable FPGA context; PL alone is ambiguous when
# another FPGA cable is attached to the hardware server.
targets -set -filter {name == "PS TAP"}
fpga -file $bit
targets -set -filter {name =~ "PSU"}
source $init
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config
targets -set -filter {name =~ "Cortex-R5 #0"}
rst -processor -clear-registers
dow $elf
if {!$halt} {con}
after 1000
puts [targets]
if {$halt} {
    puts "R5-0 loaded and halted at entry; arm ILAs before continuing."
} else {
    puts "R5-0 started; monitor UART1 at 115200 8N1 (10.0.1.107:2323)."
}
exit
