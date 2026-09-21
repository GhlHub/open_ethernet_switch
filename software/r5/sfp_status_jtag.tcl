# Read SFP identity and PHY status through the PL AXI IIC, leaving R5 running.
# Requires exclusive IIC access (the current R5 firmware does not use this core).
# No EEPROM data or PHY configuration is written; only read offsets are selected.
connect -url [expr {[llength $argv] ? [lindex $argv 0] : "tcp:10.0.1.109:3121"}]
targets -set -filter {name =~ "PSU"}
proc iic_rd {off} {return [mrd -force -value [expr {0x80030000+$off}]]}
proc iic_wr {off value} {mwr -force [expr {0x80030000+$off}] $value}
if {[iic_rd 0x104]&4} {error "IIC bus busy; refusing to interrupt a transaction"}
iic_wr 0x40 0xa
iic_wr 0x120 15
iic_wr 0x100 2
iic_wr 0x100 1
proc read_bytes {address offset count} {
 if {$count<1 || $count>16} {error "Use a 1..16-byte transaction"}
 iic_wr 0x108 [expr {0x100|($address<<1)}]
 iic_wr 0x108 $offset
 iic_wr 0x108 [expr {0x101|($address<<1)}]
 iic_wr 0x108 [expr {0x200|$count}]
 set result {}
 set limit [expr {[clock milliseconds]+2000}]
 for {set i 0} {$i<$count} {incr i} {
  while {[iic_rd 0x104]&0x40} {
   if {[clock milliseconds]>$limit} {error "IIC timeout address=$address offset=$offset SR=[iic_rd 0x104] ISR=[iic_rd 0x20]"}
   after 1
  }
  lappend result [expr {[iic_rd 0x10c]&255}]
 }
 return $result
}
set bytes {}
for {set off 0} {$off<96} {incr off 16} {lappend bytes {*}[read_bytes 0x50 $off 16]}
puts "EEPROM=$bytes"
foreach {name first last check} {base 0 62 63 extended 64 94 95} {
 set sum 0
 foreach b [lrange $bytes $first $last] {incr sum $b}
 set expected [expr {$sum & 255}]
 set actual [lindex $bytes $check]
 puts [format {EEPROM %s checksum: expected=%02x actual=%02x valid=%d} $name $expected $actual [expr {$expected==$actual}]]
 if {$expected!=$actual} {error "Invalid SFP EEPROM $name checksum"}
}
foreach {name start end} {vendor 20 35 part 40 55 revision 56 59 serial 68 83} {
 set chars ""
 foreach b [lrange $bytes $start $end] {append chars [format %c $b]}
 puts "$name=$chars"
}
# Standard copper SFP PHY address; optical modules may not implement it.
foreach reg {0 1 2 3 4 5 9 10 16 17 20 27} {
 set data [read_bytes 0x56 $reg 2]
 puts [format {PHY[%02d]=%04x} $reg [expr {([lindex $data 0]<<8)|[lindex $data 1]}]]
}
exit
