# Preserve the native board wrapper's non-cacheable DDR transaction attributes.
# AXI's default for an omitted AxCACHE signal is 0011; that would change the
# previous 0000 ties when the partial fabric interfaces connect directly in BD.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant ddr_cache_zero
set_property -dict {CONFIG.CONST_WIDTH 4 CONFIG.CONST_VAL 0} [get_bd_cells ddr_cache_zero]
foreach pin {S00_AXI_awcache S01_AXI_arcache S02_AXI_awcache S02_AXI_arcache} {
    connect_bd_net [get_bd_pins ddr_cache_zero/dout] [get_bd_pins sc_ddr/$pin]
}
