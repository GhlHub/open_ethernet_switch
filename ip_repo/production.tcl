# Production digital IP assembly. Connections preserve the native switch ABI.
# Sourced after PS, DMA and board-facing ports exist, before address assignment.
foreach {cell type} {fabric switch_fabric gem0 gem_port gem1 gem_port pl0 pl_port pl1 pl_port sfp sfp_port management management} {
    create_bd_cell -type ip -vlnv ghlhub.org:ethernet:$type:1.0 $cell
}
foreach cell {fabric management} {
    set_property -dict [list CONFIG.STATS_DDR $stats_ddr CONFIG.STATS_DEBUG $stats_debug] [get_bd_cells $cell]
}
set_property -dict {CONFIG.AN_BREAK_LINK_CYCLES 1250000 CONFIG.AN_LINK_TIMER_CYCLES 1250000 CONFIG.AN_IDLE_DETECT_CYCLES 1250000} [get_bd_cells sfp]
create_bd_cell -type module -reference switch_stats_router stats_router
# Replace former RTL-facing interfaces with catalog IP connections.
proc replace_external_interface {name pin} {
    set port [get_bd_intf_ports $name]
    set peers [get_bd_intf_pins -of_objects [get_bd_intf_nets -of_objects $port]]
    delete_bd_objs $port
    connect_bd_intf_net {*}$peers [get_bd_intf_pins $pin]
}
replace_external_interface m_axi_ing fabric/m_axi_ing
replace_external_interface m_axi_egr fabric/m_axi_egr
replace_external_interface m_axi_cpu fabric/m_axi_cpu
replace_external_interface cpu_s_axis fabric/cpu_s_axis
replace_external_interface cpu_m_axis fabric/cpu_m_axis
replace_external_interface pl0_s_axi pl0/s_axi
replace_external_interface pl1_s_axi pl1/s_axi
replace_external_interface sfp_s_axi sfp/s_axi
replace_external_interface diag_s_axi management/s_axi
connect_bd_intf_net [get_bd_intf_pins gem0/m_axis] [get_bd_intf_pins fabric/s00_axis]
connect_bd_intf_net [get_bd_intf_pins gem0/s_axis] [get_bd_intf_pins fabric/m00_axis]
connect_bd_intf_net [get_bd_intf_pins gem1/m_axis] [get_bd_intf_pins fabric/s01_axis]
connect_bd_intf_net [get_bd_intf_pins gem1/s_axis] [get_bd_intf_pins fabric/m01_axis]
connect_bd_intf_net [get_bd_intf_pins pl0/m_axis] [get_bd_intf_pins fabric/s02_axis]
connect_bd_intf_net [get_bd_intf_pins pl0/s_axis] [get_bd_intf_pins fabric/m02_axis]
connect_bd_intf_net [get_bd_intf_pins pl1/m_axis] [get_bd_intf_pins fabric/s03_axis]
connect_bd_intf_net [get_bd_intf_pins pl1/s_axis] [get_bd_intf_pins fabric/m03_axis]
connect_bd_intf_net [get_bd_intf_pins sfp/m_axis] [get_bd_intf_pins fabric/s04_axis]
connect_bd_intf_net [get_bd_intf_pins sfp/s_axis] [get_bd_intf_pins fabric/m04_axis]
source $root/ip_repo/axi_attributes.tcl

# Explicit scalar nets include clocks, resets, mailbox and management sidebands.
# A retained board port marks a physical-shell boundary; other old ports disappear.
proc digital_net {name retain pins} {
    set port [get_bd_ports -quiet $name]
    if {[llength $port] && !$retain} {
        set peers [get_bd_pins -of_objects [get_bd_nets -of_objects $port]]
        set anchor [lindex $peers 0]
        delete_bd_objs $port
        foreach pin $pins {connect_bd_net [get_bd_pins $anchor] [get_bd_pins $pin]}
    } elseif {[llength $port]} {
        foreach pin $pins {connect_bd_net $port [get_bd_pins $pin]}
    } elseif {$retain} {
        set pin [get_bd_pins [lindex $pins 0]]
        make_bd_pins_external -name $name $pin
        set port [get_bd_ports $name]
        foreach other [lrange $pins 1 end] {connect_bd_net $port [get_bd_pins $other]}
        if {[get_property TYPE $pin] eq "clk"} {
            set hz 125000000
            if {[string match gth_clk* $name]} {set hz 62500000}
            set_property CONFIG.FREQ_HZ $hz $port
        }
    } else {
        foreach pin [lrange $pins 1 end] {
            connect_bd_net [get_bd_pins [lindex $pins 0]] [get_bd_pins $pin]
        }
    }
}

digital_net fabric_clk_o 1 {fabric/clk gem0/clk gem1/clk pl0/clk pl1/clk sfp/clk}
digital_net fabric_rst_n_o 1 {fabric/rst_n gem0/rst_n gem1/rst_n pl0/rst_n pl1/rst_n sfp/rst_n}
digital_net axis_clk 1 {fabric/axis_clk pl0/axis_clk pl1/axis_clk sfp/axis_clk management/clk}
digital_net axis_rst_n 1 {fabric/axis_rst_n pl0/axis_rst_n pl1/axis_rst_n sfp/axis_rst_n management/rst_n}
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant default_age
set_property -dict {CONFIG.CONST_WIDTH 9 CONFIG.CONST_VAL 300} [get_bd_cells default_age]
connect_bd_net [get_bd_pins {default_age/dout fabric/default_age_i}]
digital_net link_up_axi 0 {fabric/link_up_i management/link_up_o}
digital_net link_tog_axi 0 {fabric/link_flush_tog_i management/link_flush_tog_o}
digital_net link_flush_busy 0 {fabric/link_flush_busy_o management/link_flush_busy_i}
digital_net learn_en_axi 0 {fabric/learn_en_i management/learn_en_o}
digital_net fwd_en_axi 0 {fabric/fwd_en_i management/fwd_en_o}
digital_net cpu_ovr_mask_axi 0 {fabric/cpu_tx_ovr_mask_i management/cpu_tx_ovr_mask_o}
digital_net cpu_ovr_go_axi 0 {fabric/cpu_tx_ovr_go_i management/cpu_tx_ovr_go_o}
digital_net cpu_rx_tag 0 {fabric/cpu_rx_ingress_port_o management/cpu_rx_tag_i}
digital_net cpu_rx_tag_valid 0 {fabric/cpu_rx_ingress_valid_o management/cpu_rx_tag_valid_i}
digital_net cpu_rx_tag_pop 0 {fabric/cpu_rx_ingress_pop_i management/cpu_rx_tag_pop_o}
digital_net fabric_req 0 {fabric/stats_req stats_router/fabric_req}
digital_net stats_select 0 {fabric/stats_select gem0/stats_select gem1/stats_select pl0/stats_select pl1/stats_select sfp/stats_select stats_router/stats_select}
digital_net fabric_acks 0 {fabric/stats_acks stats_router/fabric_acks}
digital_net fabric_values 0 {fabric/stats_values stats_router/fabric_values}
digital_net gem0_req 0 {gem0/stats_req stats_router/gem0_req}
digital_net gem0_acks 0 {gem0/stats_acks stats_router/gem0_acks}
digital_net gem0_values 0 {gem0/stats_values stats_router/gem0_values}
digital_net gem0_rx_clk 1 {gem0/gem_rx_clk}
digital_net gem0_rx_rst_n 1 {gem0/gem_rx_rst_n}
digital_net gem0_tx_clk 1 {gem0/gem_tx_clk}
digital_net gem0_tx_rst_n 1 {gem0/gem_tx_rst_n}
digital_net gem0_rx_w_data_i 0 {gem0/rx_w_data_i}
digital_net gem0_rx_w_wr_i 0 {gem0/rx_w_wr_i}
digital_net gem0_rx_w_sop_i 0 {gem0/rx_w_sop_i}
digital_net gem0_rx_w_eop_i 0 {gem0/rx_w_eop_i}
digital_net gem0_rx_w_err_i 0 {gem0/rx_w_err_i}
digital_net gem0_rx_w_flush_i 0 {gem0/rx_w_flush_i}
digital_net gem0_rx_w_status_i 0 {gem0/rx_w_status_i}
digital_net gem0_rx_w_overflow_o 0 {gem0/rx_w_overflow_o}
# GEM receive status echo is unused by the PS.
digital_net gem0_tx_r_rd_i 0 {gem0/tx_r_rd_i}
digital_net gem0_tx_r_data_rdy_o 0 {gem0/tx_r_data_rdy_o}
digital_net gem0_tx_r_valid_o 0 {gem0/tx_r_valid_o}
digital_net gem0_tx_r_data_o 0 {gem0/tx_r_data_o}
digital_net gem0_tx_r_sop_o 0 {gem0/tx_r_sop_o}
digital_net gem0_tx_r_eop_o 0 {gem0/tx_r_eop_o}
digital_net gem0_tx_r_err_o 0 {gem0/tx_r_err_o}
digital_net gem0_tx_r_underflow_o 0 {gem0/tx_r_underflow_o}
digital_net gem0_tx_r_flushed_o 0 {gem0/tx_r_flushed_o}
digital_net gem0_tx_r_control_o 0 {gem0/tx_r_control_o}
digital_net gem0_dma_tx_end_tog_i 0 {gem0/dma_tx_end_tog_i}
digital_net gem0_dma_tx_status_tog_o 0 {gem0/dma_tx_status_tog_o}
digital_net gem0_tx_r_status_i 0 {gem0/tx_r_status_i}
digital_net gem1_req 0 {gem1/stats_req stats_router/gem1_req}
digital_net gem1_acks 0 {gem1/stats_acks stats_router/gem1_acks}
digital_net gem1_values 0 {gem1/stats_values stats_router/gem1_values}
digital_net gem1_rx_clk 1 {gem1/gem_rx_clk}
digital_net gem1_rx_rst_n 1 {gem1/gem_rx_rst_n}
digital_net gem1_tx_clk 1 {gem1/gem_tx_clk}
digital_net gem1_tx_rst_n 1 {gem1/gem_tx_rst_n}
digital_net gem1_rx_w_data_i 0 {gem1/rx_w_data_i}
digital_net gem1_rx_w_wr_i 0 {gem1/rx_w_wr_i}
digital_net gem1_rx_w_sop_i 0 {gem1/rx_w_sop_i}
digital_net gem1_rx_w_eop_i 0 {gem1/rx_w_eop_i}
digital_net gem1_rx_w_err_i 0 {gem1/rx_w_err_i}
digital_net gem1_rx_w_flush_i 0 {gem1/rx_w_flush_i}
digital_net gem1_rx_w_status_i 0 {gem1/rx_w_status_i}
digital_net gem1_rx_w_overflow_o 0 {gem1/rx_w_overflow_o}
# GEM receive status echo is unused by the PS.
digital_net gem1_tx_r_rd_i 0 {gem1/tx_r_rd_i}
digital_net gem1_tx_r_data_rdy_o 0 {gem1/tx_r_data_rdy_o}
digital_net gem1_tx_r_valid_o 0 {gem1/tx_r_valid_o}
digital_net gem1_tx_r_data_o 0 {gem1/tx_r_data_o}
digital_net gem1_tx_r_sop_o 0 {gem1/tx_r_sop_o}
digital_net gem1_tx_r_eop_o 0 {gem1/tx_r_eop_o}
digital_net gem1_tx_r_err_o 0 {gem1/tx_r_err_o}
digital_net gem1_tx_r_underflow_o 0 {gem1/tx_r_underflow_o}
digital_net gem1_tx_r_flushed_o 0 {gem1/tx_r_flushed_o}
digital_net gem1_tx_r_control_o 0 {gem1/tx_r_control_o}
digital_net gem1_dma_tx_end_tog_i 0 {gem1/dma_tx_end_tog_i}
digital_net gem1_dma_tx_status_tog_o 0 {gem1/dma_tx_status_tog_o}
digital_net gem1_tx_r_status_i 0 {gem1/tx_r_status_i}
digital_net pl0_req 0 {pl0/stats_request stats_router/pl0_req}
digital_net pl0_acks 0 {pl0/stats_ack stats_router/pl0_acks}
digital_net pl0_values 0 {pl0/stats_value stats_router/pl0_values}
digital_net gtx_clk_pl0 1 {pl0/gtx_clk}
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant mac_enable
set_property -dict {CONFIG.CONST_WIDTH 1 CONFIG.CONST_VAL 1} [get_bd_cells mac_enable]
connect_bd_net [get_bd_pins {mac_enable/dout pl0/clk_en pl1/clk_en sfp/clk_en}]
digital_net pl0_gmii_rxd 1 {pl0/gmii_rxd}
digital_net pl0_gmii_rx_dv 1 {pl0/gmii_rx_dv}
digital_net pl0_gmii_rx_er 1 {pl0/gmii_rx_er}
digital_net pl0_gmii_txd 1 {pl0/gmii_txd}
digital_net pl0_gmii_tx_en 1 {pl0/gmii_tx_en}
digital_net pl0_gmii_tx_er 1 {pl0/gmii_tx_er}
digital_net pl0_interrupt 0 {pl0/interrupt}
digital_net pl0_mac_irq 0 {pl0/mac_irq}
digital_net pl1_req 0 {pl1/stats_request stats_router/pl1_req}
digital_net pl1_acks 0 {pl1/stats_ack stats_router/pl1_acks}
digital_net pl1_values 0 {pl1/stats_value stats_router/pl1_values}
digital_net gtx_clk_pl1 1 {pl1/gtx_clk}
digital_net pl1_gmii_rxd 1 {pl1/gmii_rxd}
digital_net pl1_gmii_rx_dv 1 {pl1/gmii_rx_dv}
digital_net pl1_gmii_rx_er 1 {pl1/gmii_rx_er}
digital_net pl1_gmii_txd 1 {pl1/gmii_txd}
digital_net pl1_gmii_tx_en 1 {pl1/gmii_tx_en}
digital_net pl1_gmii_tx_er 1 {pl1/gmii_tx_er}
digital_net pl1_interrupt 0 {pl1/interrupt}
digital_net pl1_mac_irq 0 {pl1/mac_irq}
digital_net sfp_req 0 {sfp/stats_request stats_router/sfp_req}
digital_net sfp_acks 0 {sfp/stats_ack stats_router/sfp_acks}
digital_net sfp_values 0 {sfp/stats_value stats_router/sfp_values}
digital_net gtx_clk_sfp 1 {sfp/gtx_clk}
digital_net gtx_rst_n_sfp 1 {sfp/gtx_rst_n}
digital_net gth_clk_sfp 1 {sfp/gth_clk}
digital_net gth_rst_n_sfp 1 {sfp/gth_rst_n}
digital_net sfp_txdata 1 {sfp/txdata_o}
digital_net sfp_txcharisk 1 {sfp/txcharisk_o}
digital_net sfp_rxdata 1 {sfp/rxdata_i}
digital_net sfp_rxcharisk 1 {sfp/rxcharisk_i}
digital_net sfp_rxdisperr 1 {sfp/rxdisperr_i}
digital_net sfp_rxnotintable 1 {sfp/rxnotintable_i}
digital_net sfp_sync_ok 1 {sfp/sync_ok_o}
digital_net sfp_an_link_up 1 {sfp/an_link_up_o}
digital_net sfp_an_duplex_full 1 {sfp/an_duplex_full_o}
# Unused output: sfp/an_pause_o (sfp_an_pause)
digital_net sfp_an_remote_fault 1 {sfp/an_remote_fault_o}
digital_net sfp_interrupt 0 {sfp/interrupt}
digital_net sfp_mac_irq 0 {sfp/mac_irq}
digital_net stats_request 0 {management/stats_request stats_router/stats_request}
digital_net stats_index 0 {management/stats_index stats_router/stats_index}
digital_net stats_ack 0 {management/stats_ack stats_router/stats_ack}
digital_net stats_value 0 {management/stats_value stats_router/stats_value}
digital_net diag_flags 1 {management/flags_i}
digital_net idelay_rdy_axi 1 {management/idelay_rdy_i}
digital_net diag_clr 1 {management/clear_o}
digital_net phy_link 1 {management/phy_link_i}
digital_net link_event_set 1 {management/link_event_set_i}
digital_net link_irq 0 {management/link_irq_o}
digital_net sfp_sb_status 1 {management/sfp_status_i}
digital_net sfp_pcs_s2 1 {management/sfp_pcs_status_i}
digital_net sfp_sb_force 1 {management/sfp_force_disable_o}
digital_net sfp_sb_clr_fault 1 {management/sfp_clr_fault_seen_o}
digital_net sfp_sb_clr_removed 1 {management/sfp_clr_removed_seen_o}
digital_net sfp_sb_clr_lockout 1 {management/sfp_clr_lockout_o}
set_property CONFIG.ASSOCIATED_BUSIF {mdio0_s_axi:mdio1_s_axi} [get_bd_ports axis_clk]
set_property CONFIG.ASSOCIATED_BUSIF {} [get_bd_ports fabric_clk_o]
# These resets are synchronized in the retained board shell, each to the
# corresponding PS FIFO clock. Describe that relationship across the BD boundary.
foreach g {0 1} {
    foreach d {rx tx} {
        set_property CONFIG.ASSOCIATED_RESET gem${g}_${d}_rst_n [get_bd_ports gem${g}_${d}_clk]
    }
}
