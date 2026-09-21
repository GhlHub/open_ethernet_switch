# Read-only live checks. Run after boot_jtag.tcl; leaves R5 running.
set root [file normalize [file join [file dirname [info script]] ../..]]
cd $root
set url [expr {[llength $argv] ? [lindex $argv 0] : "tcp:10.0.1.109:3121"}]
set nm /tools/Xilinx/2026.1/gnu/armr5/lin/gcc-arm-none-eabi/bin/armr5-none-eabi-nm
set symbols [exec $nm software/r5/out/kr260_r5.elf]
proc symbol_address {name} {
    global symbols
    if {![regexp -line [format {^([0-9a-fA-F]+) [A-Za-z] %s$} $name] $symbols -> hex]} {
        error "Missing ELF symbol $name"
    }
    return [expr "0x$hex"]
}
connect -url $url
targets -set -filter {name =~ "PSU"}
puts [targets]
set ticks [symbol_address xTickCount]
set t0 [clock milliseconds]
set tick0 [mrd -value $ticks]
set stamp0 [mrd -value 0xff120018]
after 5000
set tick1 [mrd -value $ticks]
set stamp1 [mrd -value 0xff120018]
set dt [expr {[clock milliseconds]-$t0}]
puts "elapsed_ms=$dt tick_delta=[expr {($tick1-$tick0)&0xffffffff}] timestamp_delta=[expr {($stamp1-$stamp0)&0xffffffff}]"
puts "Expected approximately 781250 timestamp counts/s; JTAG reads add sampling skew."
puts "R5 D-cache is enabled: DDR symbols (including xTickCount) may be stale through PSU reads. Use UART/network traffic to confirm firmware liveness."
puts "PHY initialization flags (low two bytes):"
puts [mrd [symbol_address ps_ready]]
puts "Fabric diagnostics (LINK_STATUS at +0x14):"
puts [mrd -force 0x80100000 9]
puts "PL0/PL1 PHY status:"
puts [mrd -force 0x80010010]
puts [mrd -force 0x80020010]
puts "AXI DMA MM2S / S2MM status:"
puts [mrd -force 0x80000004]
puts [mrd -force 0x80000034]
puts "UART dropped character count:"
puts [mrd [symbol_address board_uart_dropped]]
puts "GEM1 TX frame / TX underrun / RX frame counters (clear on read):"
foreach addr {0xff0c0108 0xff0c0134 0xff0c0158} {puts [mrd $addr]}
exit
