# Read non-cacheable DMA counters without stopping R5. Use the deployed ELF.
# xsdb software/r5/dma_status_jtag.tcl [hw_server_url]
set root [file normalize [file join [file dirname [info script]] ../..]]
cd $root
set url [expr {[llength $argv] ? [lindex $argv 0] : "tcp:10.0.1.109:3121"}]
set nm /tools/Xilinx/2026.1/gnu/armr5/lin/gcc-arm-none-eabi/bin/armr5-none-eabi-nm
set symbols [exec $nm software/r5/out/kr260_r5.elf]
if {![regexp -line {^([0-9a-fA-F]+) [A-Za-z] fabric_dma_counters$} $symbols -> hex]} {
    error "Missing DMA counters in ELF"
}
set address [expr "0x$hex"]
connect -url $url
targets -set -filter {name =~ "PSU"}
puts "DMA MM2S control/status:"
puts [mrd -force 0x80000000 2]
puts "DMA S2MM control/status:"
puts [mrd -force 0x80000030 2]
puts "DMA counters (non-cacheable):"
foreach name {tx_irq rx_irq error_irq tx_completed rx_consumed rx_dropped tx_timeouts} {
    puts "$name=[mrd -value $address]"
    incr address 4
}
# The RPU-local GIC is not readable through the PSU debug AP. IRQ counters
# above are written by the actual interrupt handlers, not by packet tasks.
exit
