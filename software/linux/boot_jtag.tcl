# Volatile A53 Linux + R5 switch boot. Never writes QSPI or removable storage.
# xsdb software/linux/boot_jtag.tcl <hw_server_url> <bitstream> [payload_dir]
if {[llength $argv] < 2 || [llength $argv] > 3} {
    error "Usage: boot_jtag.tcl <hw_server_url> <bitstream> \[payload_dir\]"
}
set root [file normalize [file join [file dirname [info script]] ../..]]
cd $root
set url [lindex $argv 0]
set bit [file normalize [lindex $argv 1]]
set payload [file normalize build/linux]
if {[llength $argv] == 3} {set payload [file normalize [lindex $argv 2]]}
set fsbl build/r5/workspace/kr260_r5/zynqmp_fsbl/build/fsbl.elf
set init build/r5/workspace/kr260_r5/hw/sdt/psu_init.tcl
foreach f [concat [list $bit $fsbl $init] [lmap name {
    Image system.dtb rootfs.cpio.gz entry.elf bl31.elf pmufw.elf r5-linux.elf manifest.json
} {file join $payload $name}]] {
    if {![file isfile $f]} {error "Missing build output: $f"}
}
# Check staged artifacts before replacing the running session.
exec python3 [file join $root software/linux/verify.py] $payload
set nm /tools/Xilinx/2026.1/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-nm
if {![regexp -line {^([0-9a-fA-F]+) [Tt] XFsbl_Exit$} [exec $nm $fsbl] -> exit_hex]} {
    error "FSBL has no XFsbl_Exit symbol"
}
connect -url $url
targets -set -filter {name =~ "PSU"}
set boot [mrd -value 0xff5e0200]
set breakpoint ""
try {
    mwr 0xff5e0200 0x100
    rst -system
    after 2000
    targets -set -filter {name =~ "PSU"}
    mwr 0xffca0038 0x1ff
    targets -set -filter {name =~ "MicroBlaze PMU"}
    dow [file join $payload pmufw.elf]
    con
    after 500
    targets -set -filter {name =~ "Cortex-A53 #0"}
    catch {stop}
    rst -processor -clear-registers
    dow $fsbl
    set breakpoint [bpadd -addr [expr "0x$exit_hex"] -type hw]
    con -block -timeout 45
    bpremove $breakpoint
    set breakpoint ""
    targets -set -filter {name =~ "PSU"}
    set status [mrd -value 0xffd80060]
    if {$status != 0} {error [format "FSBL failed: status 0x%08x" $status]}
    puts "FSBL complete; PMU firmware running"
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
    puts "Programming existing switch bitstream"
    targets -set -filter {name == "PS TAP"}
    fpga -file $bit
    targets -set -filter {name =~ "PSU"}
    source $init
    psu_ps_pl_isolation_removal
    psu_ps_pl_reset_config
    targets -set -filter {name =~ "Cortex-R5 #0"}
    rst -processor -clear-registers
    dow [file join $payload r5-linux.elf]
    # FSBL has cleaned/disabled its D-cache before XFsbl_Exit. Transfer physical
    # DDR payloads through PSU, avoiding slow per-access A53 debug operations.
    targets -set -filter {name =~ "PSU"}
    puts "Loading Linux Image (JTAG transfer can take several minutes)"
    dow -data [file join $payload Image] 0x00200000
    dow -data [file join $payload system.dtb] 0x04000000
    dow -data [file join $payload rootfs.cpio.gz] 0x06000000
    targets -set -filter {name =~ "Cortex-A53 #0"}
    dow [file join $payload entry.elf]
    # Load TF-A last, replacing FSBL in OCM and setting A53 PC to BL31.
    dow [file join $payload bl31.elf]
    puts "Starting TF-A and Linux"
    con
    after 15000
    targets -set -filter {name =~ "Cortex-R5 #0"}
    con
    puts "A53 Linux and R5 started. Verify KR260_MINIMAL_LINUX_READY on UART1."
} finally {
    if {$breakpoint ne ""} {
        targets -set -filter {name =~ "Cortex-A53 #0"}
        catch {bpremove $breakpoint}
    }
    targets -set -filter {name =~ "PSU"}
    mwr 0xff5e0200 $boot
}
exit
