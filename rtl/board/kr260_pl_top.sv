// kr260_pl_top.sv
//
// KR260 PL-side board wrapper: joins switch_top.sv to the board-level
// pieces that already existed as separate, individually-tested modules --
// two PL RGMII PHY interfaces (rgmii_gmii_adapter.sv + pl_eth_clk_gen.sv +
// mdio_controller.sv each) and the SFP GTH transceiver (gth_sfp_wrapper.sv
// + sfp_pcs_clk_gen.sv) -- and exposes everything that has to reach the
// Zynq PS (AXI masters/slaves, GEM external-FIFO ports, CPU AXI-Stream,
// interrupts) as plain ports, named exactly as switch_top.sv names them,
// for the block design in build/ to connect.
//
// Clocking (see docs/board-integration.md):
//   - fabric clk (100 MHz) = PL0's pl_eth_clk_gen clk_o; PL1's copy is
//     generated (each port needs its own 125/300 MHz) but its 100 MHz
//     output is unused. Every AXI master below runs on this clock, so the
//     PS HP ports/interconnect must be clocked from fabric_clk_o.
//   - axis_clk (150 MHz), axis_rst_n, freerun_clk (50 MHz) and ps_rst_n
//     come from the PS (pl_clk0/pl_clk1, proc_sys_reset).
//   - gemN_rx_clk/gemN_tx_clk: the PS's separate GEM FIFO RX and TX clocks
//     (fmio_gemN_fifo_rx/tx_clk_to_pl_bufg), each with its own reset.
//
// NOT validated on hardware. Known assumptions, all listed in
// docs/inventory.md "Known gaps": RGMII delays/timing, GEM clocking above,
// SFP MMCM-to-GT phase (checked only by static timing), SFP sideband and
// the unconnected SFP module I2C.

module kr260_pl_top
  import buf_mgr_pkg::*;
  import axi_dma_pkg::*;
  import mac_table_pkg::*;
#(parameter bit STATS_DDR=0, STATS_DEBUG=0) (
  // ---- from the PS block design ----
  input  logic ps_rst_n,          // async, e.g. pl_resetn0
  input  logic freerun_clk,       // 50 MHz, GTH reset controller / DRP
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 fabric_clk_o CLK", X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axi_ing:m_axi_egr:m_axi_cpu:cpu_s_axis:cpu_m_axis, ASSOCIATED_RESET fabric_rst_n_o, FREQ_HZ 100000000" *)
  output logic fabric_clk_o,      // 100 MHz: clock for every AXI master below
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 fabric_rst_n_o RST", X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  output logic fabric_rst_n_o,

  // ---- PL0 PHY (KR260 J10 upper port) ----
  input  logic       pl0_ref_clk_25m,
  output logic [3:0] pl0_rgmii_txd,
  output logic       pl0_rgmii_tx_ctl,
  output logic       pl0_rgmii_txc,
  input  logic [3:0] pl0_rgmii_rxd,
  input  logic       pl0_rgmii_rx_ctl,
  input  logic       pl0_rgmii_rxc,
  inout  wire        pl0_mdio,
  output logic       pl0_mdc,
  output logic       pl0_phy_reset_n,

  // ---- PL1 PHY ----
  input  logic       pl1_ref_clk_25m,
  output logic [3:0] pl1_rgmii_txd,
  output logic       pl1_rgmii_tx_ctl,
  output logic       pl1_rgmii_txc,
  input  logic [3:0] pl1_rgmii_rxd,
  input  logic       pl1_rgmii_rx_ctl,
  input  logic       pl1_rgmii_rxc,
  inout  wire        pl1_mdio,
  output logic       pl1_mdc,
  output logic       pl1_phy_reset_n,

  // ---- SFP+ cage ----
  input  logic sfp_refclk_p,      // 156.25 MHz, U90
  input  logic sfp_refclk_n,
  output logic sfp_txp,
  output logic sfp_txn,
  input  logic sfp_rxp,
  input  logic sfp_rxn,
  input  logic sfp_los,
  input  logic sfp_mod_abs,
  input  logic sfp_tx_fault,
  output logic sfp_tx_disable,
  output logic [1:0] sfp_led,     // {LED2, LED1}: link_up, sync_ok
  output logic       link_irq,    // to PS pl_ps_irq1[1]: an enabled LINK_EVENT bit is set

  // ---- AXI4-Lite: MDIO controllers (axis_clk domain) ----
  input  logic [7:0]  mdio0_s_axi_awaddr,
  input  logic        mdio0_s_axi_awvalid,
  output logic        mdio0_s_axi_awready,
  input  logic [31:0] mdio0_s_axi_wdata,
  input  logic [3:0]  mdio0_s_axi_wstrb,
  input  logic        mdio0_s_axi_wvalid,
  output logic        mdio0_s_axi_wready,
  output logic [1:0]  mdio0_s_axi_bresp,
  output logic        mdio0_s_axi_bvalid,
  input  logic        mdio0_s_axi_bready,
  input  logic [7:0]  mdio0_s_axi_araddr,
  input  logic        mdio0_s_axi_arvalid,
  output logic        mdio0_s_axi_arready,
  output logic [31:0] mdio0_s_axi_rdata,
  output logic [1:0]  mdio0_s_axi_rresp,
  output logic        mdio0_s_axi_rvalid,
  input  logic        mdio0_s_axi_rready,

  input  logic [7:0]  mdio1_s_axi_awaddr,
  input  logic        mdio1_s_axi_awvalid,
  output logic        mdio1_s_axi_awready,
  input  logic [31:0] mdio1_s_axi_wdata,
  input  logic [3:0]  mdio1_s_axi_wstrb,
  input  logic        mdio1_s_axi_wvalid,
  output logic        mdio1_s_axi_wready,
  output logic [1:0]  mdio1_s_axi_bresp,
  output logic        mdio1_s_axi_bvalid,
  input  logic        mdio1_s_axi_bready,
  input  logic [7:0]  mdio1_s_axi_araddr,
  input  logic        mdio1_s_axi_arvalid,
  output logic        mdio1_s_axi_arready,
  output logic [31:0] mdio1_s_axi_rdata,
  output logic [1:0]  mdio1_s_axi_rresp,
  output logic        mdio1_s_axi_rvalid,
  input  logic        mdio1_s_axi_rready,

  // ---- AXI4-Lite: RGMII RX diagnostics (axis_clk domain) ----
  input  logic [7:0]  diag_s_axi_awaddr,
  input  logic        diag_s_axi_awvalid,
  output logic        diag_s_axi_awready,
  input  logic [31:0] diag_s_axi_wdata,
  input  logic [3:0]  diag_s_axi_wstrb,
  input  logic        diag_s_axi_wvalid,
  output logic        diag_s_axi_wready,
  output logic [1:0]  diag_s_axi_bresp,
  output logic        diag_s_axi_bvalid,
  input  logic        diag_s_axi_bready,
  input  logic [7:0]  diag_s_axi_araddr,
  input  logic        diag_s_axi_arvalid,
  output logic        diag_s_axi_arready,
  output logic [31:0] diag_s_axi_rdata,
  output logic [1:0]  diag_s_axi_rresp,
  output logic        diag_s_axi_rvalid,
  input  logic        diag_s_axi_rready,

  // ---- everything else: switch_top's own ports, same names ----
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 axis_clk CLK", X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF pl0_s_axi:pl1_s_axi:sfp_s_axi:mdio0_s_axi:mdio1_s_axi:diag_s_axi, ASSOCIATED_RESET axis_rst_n, FREQ_HZ 150000000" *)
  input logic axis_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 axis_rst_n RST", X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input logic axis_rst_n,
  input logic gem0_rx_clk,
  input logic gem0_tx_clk,
  input logic gem1_rx_clk,
  input logic gem1_tx_clk,
  input logic [7:0] gem0_rx_w_data_i,
  input logic gem0_rx_w_wr_i,
  input logic gem0_rx_w_sop_i,
  input logic gem0_rx_w_eop_i,
  input logic gem0_rx_w_err_i,
  input logic gem0_rx_w_flush_i,
  input logic [44:0] gem0_rx_w_status_i,
  output logic gem0_rx_w_overflow_o,
  output logic [44:0] gem0_rx_w_status_o,
  input logic gem0_tx_r_rd_i,
  output logic gem0_tx_r_data_rdy_o,
  output logic gem0_tx_r_valid_o,
  output logic [7:0] gem0_tx_r_data_o,
  output logic gem0_tx_r_sop_o,
  output logic gem0_tx_r_eop_o,
  output logic gem0_tx_r_err_o,
  output logic gem0_tx_r_underflow_o,
  output logic gem0_tx_r_flushed_o,
  output logic gem0_tx_r_control_o,
  input logic gem0_dma_tx_end_tog_i,
  output logic gem0_dma_tx_status_tog_o,
  input logic [3:0] gem0_tx_r_status_i,
  input logic [7:0] gem1_rx_w_data_i,
  input logic gem1_rx_w_wr_i,
  input logic gem1_rx_w_sop_i,
  input logic gem1_rx_w_eop_i,
  input logic gem1_rx_w_err_i,
  input logic gem1_rx_w_flush_i,
  input logic [44:0] gem1_rx_w_status_i,
  output logic gem1_rx_w_overflow_o,
  output logic [44:0] gem1_rx_w_status_o,
  input logic gem1_tx_r_rd_i,
  output logic gem1_tx_r_data_rdy_o,
  output logic gem1_tx_r_valid_o,
  output logic [7:0] gem1_tx_r_data_o,
  output logic gem1_tx_r_sop_o,
  output logic gem1_tx_r_eop_o,
  output logic gem1_tx_r_err_o,
  output logic gem1_tx_r_underflow_o,
  output logic gem1_tx_r_flushed_o,
  output logic gem1_tx_r_control_o,
  input logic gem1_dma_tx_end_tog_i,
  output logic gem1_dma_tx_status_tog_o,
  input logic [3:0] gem1_tx_r_status_i,
  input logic [17:0] pl0_s_axi_awaddr,
  input logic pl0_s_axi_awvalid,
  output logic pl0_s_axi_awready,
  input logic [31:0] pl0_s_axi_wdata,
  input logic [3:0] pl0_s_axi_wstrb,
  input logic pl0_s_axi_wvalid,
  output logic pl0_s_axi_wready,
  output logic [1:0] pl0_s_axi_bresp,
  output logic pl0_s_axi_bvalid,
  input logic pl0_s_axi_bready,
  input logic [17:0] pl0_s_axi_araddr,
  input logic pl0_s_axi_arvalid,
  output logic pl0_s_axi_arready,
  output logic [31:0] pl0_s_axi_rdata,
  output logic [1:0] pl0_s_axi_rresp,
  output logic pl0_s_axi_rvalid,
  input logic pl0_s_axi_rready,
  output logic pl0_interrupt,
  output logic pl0_mac_irq,
  input logic [17:0] pl1_s_axi_awaddr,
  input logic pl1_s_axi_awvalid,
  output logic pl1_s_axi_awready,
  input logic [31:0] pl1_s_axi_wdata,
  input logic [3:0] pl1_s_axi_wstrb,
  input logic pl1_s_axi_wvalid,
  output logic pl1_s_axi_wready,
  output logic [1:0] pl1_s_axi_bresp,
  output logic pl1_s_axi_bvalid,
  input logic pl1_s_axi_bready,
  input logic [17:0] pl1_s_axi_araddr,
  input logic pl1_s_axi_arvalid,
  output logic pl1_s_axi_arready,
  output logic [31:0] pl1_s_axi_rdata,
  output logic [1:0] pl1_s_axi_rresp,
  output logic pl1_s_axi_rvalid,
  input logic pl1_s_axi_rready,
  output logic pl1_interrupt,
  output logic pl1_mac_irq,
  input logic [17:0] sfp_s_axi_awaddr,
  input logic sfp_s_axi_awvalid,
  output logic sfp_s_axi_awready,
  input logic [31:0] sfp_s_axi_wdata,
  input logic [3:0] sfp_s_axi_wstrb,
  input logic sfp_s_axi_wvalid,
  output logic sfp_s_axi_wready,
  output logic [1:0] sfp_s_axi_bresp,
  output logic sfp_s_axi_bvalid,
  input logic sfp_s_axi_bready,
  input logic [17:0] sfp_s_axi_araddr,
  input logic sfp_s_axi_arvalid,
  output logic sfp_s_axi_arready,
  output logic [31:0] sfp_s_axi_rdata,
  output logic [1:0] sfp_s_axi_rresp,
  output logic sfp_s_axi_rvalid,
  input logic sfp_s_axi_rready,
  output logic sfp_interrupt,
  output logic sfp_mac_irq,
  input logic [15:0] cpu_s_axis_tdata,
  input logic [1:0] cpu_s_axis_tkeep,
  input logic cpu_s_axis_tvalid,
  input logic cpu_s_axis_tlast,
  output logic cpu_s_axis_tready,
  output logic [15:0] cpu_m_axis_tdata,
  output logic [1:0] cpu_m_axis_tkeep,
  output logic cpu_m_axis_tvalid,
  output logic cpu_m_axis_tlast,
  input logic cpu_m_axis_tready,
  output logic [AXI_ID_W-1:0] m_axi_ing_awid,
  output logic [AXI_ADDR_W-1:0] m_axi_ing_awaddr,
  output logic [7:0] m_axi_ing_awlen,
  output logic [2:0] m_axi_ing_awsize,
  output logic [1:0] m_axi_ing_awburst,
  output logic m_axi_ing_awvalid,
  input logic m_axi_ing_awready,
  output logic [AXI_DATA_W-1:0] m_axi_ing_wdata,
  output logic [AXI_STRB_W-1:0] m_axi_ing_wstrb,
  output logic m_axi_ing_wlast,
  output logic m_axi_ing_wvalid,
  input logic m_axi_ing_wready,
  input logic [AXI_ID_W-1:0] m_axi_ing_bid,
  input logic [1:0] m_axi_ing_bresp,
  input logic m_axi_ing_bvalid,
  output logic m_axi_ing_bready,
  output logic [AXI_ID_W-1:0] m_axi_egr_arid,
  output logic [AXI_ADDR_W-1:0] m_axi_egr_araddr,
  output logic [7:0] m_axi_egr_arlen,
  output logic [2:0] m_axi_egr_arsize,
  output logic [1:0] m_axi_egr_arburst,
  output logic m_axi_egr_arvalid,
  input logic m_axi_egr_arready,
  input logic [AXI_ID_W-1:0] m_axi_egr_rid,
  input logic [AXI_DATA_W-1:0] m_axi_egr_rdata,
  input logic [1:0] m_axi_egr_rresp,
  input logic m_axi_egr_rlast,
  input logic m_axi_egr_rvalid,
  output logic m_axi_egr_rready,
  output logic [AXI_ID_W-1:0] m_axi_cpu_awid,
  output logic [AXI_ADDR_W-1:0] m_axi_cpu_awaddr,
  output logic [7:0] m_axi_cpu_awlen,
  output logic [2:0] m_axi_cpu_awsize,
  output logic [1:0] m_axi_cpu_awburst,
  output logic m_axi_cpu_awvalid,
  input logic m_axi_cpu_awready,
  output logic [AXI_DATA_W-1:0] m_axi_cpu_wdata,
  output logic [AXI_STRB_W-1:0] m_axi_cpu_wstrb,
  output logic m_axi_cpu_wlast,
  output logic m_axi_cpu_wvalid,
  input logic m_axi_cpu_wready,
  input logic [AXI_ID_W-1:0] m_axi_cpu_bid,
  input logic [1:0] m_axi_cpu_bresp,
  input logic m_axi_cpu_bvalid,
  output logic m_axi_cpu_bready,
  output logic [AXI_ID_W-1:0] m_axi_cpu_arid,
  output logic [AXI_ADDR_W-1:0] m_axi_cpu_araddr,
  output logic [7:0] m_axi_cpu_arlen,
  output logic [2:0] m_axi_cpu_arsize,
  output logic [1:0] m_axi_cpu_arburst,
  output logic m_axi_cpu_arvalid,
  input logic m_axi_cpu_arready,
  input logic [AXI_ID_W-1:0] m_axi_cpu_rid,
  input logic [AXI_DATA_W-1:0] m_axi_cpu_rdata,
  input logic [1:0] m_axi_cpu_rresp,
  input logic m_axi_cpu_rlast,
  input logic m_axi_cpu_rvalid,
  output logic m_axi_cpu_rready
);

  // ---------------------------------------------------------------------
  // PL0/PL1 clock generation (25 MHz -> 125/300/100 MHz each)
  // ---------------------------------------------------------------------
  logic gtx_clk_pl0, gtx_rst_n_pl0, idly_clk_pl0, idly_rst_n_pl0, fab_clk, fab_rst_n, lock_pl0;
  logic gtx_clk_pl1, gtx_rst_n_pl1, idly_clk_pl1, idly_rst_n_pl1, unused_clk_pl1, unused_rst_pl1, lock_pl1;

  pl_eth_clk_gen u_clkgen0 (
    .ref_clk_25m_i (pl0_ref_clk_25m), .rst_n_i (ps_rst_n),
    .gtx_clk_o (gtx_clk_pl0), .gtx_rst_n_o (gtx_rst_n_pl0),
    .idelay_refclk_o (idly_clk_pl0), .idelay_refclk_rst_n_o (idly_rst_n_pl0),
    .clk_o (fab_clk), .rst_n_o (fab_rst_n), .locked_o (lock_pl0)
  );

  pl_eth_clk_gen u_clkgen1 (
    .ref_clk_25m_i (pl1_ref_clk_25m), .rst_n_i (ps_rst_n),
    .gtx_clk_o (gtx_clk_pl1), .gtx_rst_n_o (gtx_rst_n_pl1),
    .idelay_refclk_o (idly_clk_pl1), .idelay_refclk_rst_n_o (idly_rst_n_pl1),
    .clk_o (unused_clk_pl1), .rst_n_o (unused_rst_pl1), .locked_o (lock_pl1)
  );

  assign fabric_clk_o   = fab_clk;
  assign fabric_rst_n_o = fab_rst_n;

  // PHY reset requests (to U19's sequencer, not directly the PHY RESET_B):
  // release only once this port's clocks are up.
  assign pl0_phy_reset_n = lock_pl0 & ps_rst_n;
  assign pl1_phy_reset_n = lock_pl1 & ps_rst_n;

  // ---------------------------------------------------------------------
  // PL0 / PL1 RGMII <-> GMII
  // ---------------------------------------------------------------------
  logic [7:0] pl0_gmii_rxd, pl0_gmii_txd, pl1_gmii_rxd, pl1_gmii_txd;
  logic pl0_gmii_rx_dv, pl0_gmii_rx_er, pl0_gmii_tx_en, pl0_gmii_tx_er;
  logic pl1_gmii_rx_dv, pl1_gmii_rx_er, pl1_gmii_tx_en, pl1_gmii_tx_er;

  logic [3:0] diag_flags, diag_clr;
  logic [5:0] link_up_axi, link_tog_axi, link_event_set;
  logic [1:0] phy_link, phy_link_chg;
  logic       link_flush_busy;
  logic [1:0] idelay_rdy_raw;
  (* ASYNC_REG = "TRUE" *) logic [1:0] idelay_rdy_s1, idelay_rdy_axi;
  always_ff @(posedge axis_clk) begin
    idelay_rdy_s1  <= idelay_rdy_raw;
    idelay_rdy_axi <= idelay_rdy_s1;
  end
  logic [15:0] sfp_sb_status;
  logic        sfp_sb_force, sfp_sb_clr_fault, sfp_sb_clr_removed, sfp_sb_clr_lockout;
  wire stats_request, stats_ack;
  wire [7:0] stats_index;
  wire [31:0] stats_value;
  rx_diag_regs #(.STATS_DDR(STATS_DDR),.STATS_DEBUG(STATS_DEBUG)) u_rx_diag (
    .stats_request(stats_request),.stats_index(stats_index),.stats_ack(stats_ack),.stats_value(stats_value),
    .clk (axis_clk), .rst_n (axis_rst_n),
    .s_axi_awaddr (diag_s_axi_awaddr), .s_axi_awvalid (diag_s_axi_awvalid), .s_axi_awready (diag_s_axi_awready),
    .s_axi_wdata (diag_s_axi_wdata), .s_axi_wstrb (diag_s_axi_wstrb), .s_axi_wvalid (diag_s_axi_wvalid), .s_axi_wready (diag_s_axi_wready),
    .s_axi_bresp (diag_s_axi_bresp), .s_axi_bvalid (diag_s_axi_bvalid), .s_axi_bready (diag_s_axi_bready),
    .s_axi_araddr (diag_s_axi_araddr), .s_axi_arvalid (diag_s_axi_arvalid), .s_axi_arready (diag_s_axi_arready),
    .s_axi_rdata (diag_s_axi_rdata), .s_axi_rresp (diag_s_axi_rresp), .s_axi_rvalid (diag_s_axi_rvalid), .s_axi_rready (diag_s_axi_rready),
    .flags_i (diag_flags), .idelay_rdy_i (idelay_rdy_axi), .clear_o (diag_clr),
    .link_up_o (link_up_axi), .link_flush_tog_o (link_tog_axi), .link_flush_busy_i (link_flush_busy),
    .phy_link_i (phy_link), .link_event_set_i (link_event_set), .link_irq_o (link_irq),
    .sfp_status_i (sfp_sb_status), .sfp_pcs_status_i (sfp_pcs_s2), .sfp_force_disable_o (sfp_sb_force),
    .sfp_clr_fault_seen_o (sfp_sb_clr_fault), .sfp_clr_removed_seen_o (sfp_sb_clr_removed),
    .sfp_clr_lockout_o (sfp_sb_clr_lockout)
  );

  // RX data IDELAY per port: chosen from routed setup/hold slack (PL0: 0.67/0.22 ns at 500 ps,
  // PL1: 0.94/-0.23 ns at 500 ps, then 0.21/0.70 at 1000 ps -> 750 ps) so each port window is roughly centred; re-tune after
  // large placement changes
  rgmii_gmii_adapter #(.RX_DATA_IDELAY_PS(700)) u_rgmii0 (
    .gtx_clk (gtx_clk_pl0), .gtx_rst_n (gtx_rst_n_pl0),
    .idelay_refclk_i (idly_clk_pl0), .idelay_rst_n_i (idly_rst_n_pl0),
    .rgmii_txd_o (pl0_rgmii_txd), .rgmii_tx_ctl_o (pl0_rgmii_tx_ctl), .rgmii_txc_o (pl0_rgmii_txc),
    .rgmii_rxd_i (pl0_rgmii_rxd), .rgmii_rx_ctl_i (pl0_rgmii_rx_ctl), .rgmii_rxc_i (pl0_rgmii_rxc),
    .gmii_txd_i (pl0_gmii_txd), .gmii_tx_en_i (pl0_gmii_tx_en), .gmii_tx_er_i (pl0_gmii_tx_er),
    .gmii_rxd_o (pl0_gmii_rxd), .gmii_rx_dv_o (pl0_gmii_rx_dv), .gmii_rx_er_o (pl0_gmii_rx_er),
    .diag_clk_i (axis_clk), .diag_rst_n_i (axis_rst_n),
    .diag_clr_overflow_i (diag_clr[0]), .diag_clr_underrun_i (diag_clr[1]),
    .idelay_rdy_o (idelay_rdy_raw[0]), .rx_elastic_overflow_o (diag_flags[0]), .rx_elastic_underrun_o (diag_flags[1])
  );

  rgmii_gmii_adapter #(.RX_DATA_IDELAY_PS(750)) u_rgmii1 (
    .gtx_clk (gtx_clk_pl1), .gtx_rst_n (gtx_rst_n_pl1),
    .idelay_refclk_i (idly_clk_pl1), .idelay_rst_n_i (idly_rst_n_pl1),
    .rgmii_txd_o (pl1_rgmii_txd), .rgmii_tx_ctl_o (pl1_rgmii_tx_ctl), .rgmii_txc_o (pl1_rgmii_txc),
    .rgmii_rxd_i (pl1_rgmii_rxd), .rgmii_rx_ctl_i (pl1_rgmii_rx_ctl), .rgmii_rxc_i (pl1_rgmii_rxc),
    .gmii_txd_i (pl1_gmii_txd), .gmii_tx_en_i (pl1_gmii_tx_en), .gmii_tx_er_i (pl1_gmii_tx_er),
    .gmii_rxd_o (pl1_gmii_rxd), .gmii_rx_dv_o (pl1_gmii_rx_dv), .gmii_rx_er_o (pl1_gmii_rx_er),
    .diag_clk_i (axis_clk), .diag_rst_n_i (axis_rst_n),
    .diag_clr_overflow_i (diag_clr[2]), .diag_clr_underrun_i (diag_clr[3]),
    .idelay_rdy_o (idelay_rdy_raw[1]), .rx_elastic_overflow_o (diag_flags[2]), .rx_elastic_underrun_o (diag_flags[3])
  );

  // ---------------------------------------------------------------------
  // MDIO controllers (one per independent PL PHY bus), axis_clk domain
  // ---------------------------------------------------------------------
  // PHY start-up runs when the PHY reset request is released; the request
  // comes from the PL clock-generator lock, so bring it into axis_clk.
  (* ASYNC_REG = "TRUE" *) logic [1:0] init_go0_sync, init_go1_sync;
  always_ff @(posedge axis_clk) begin
    init_go0_sync <= {init_go0_sync[0], pl0_phy_reset_n};
    init_go1_sync <= {init_go1_sync[0], pl1_phy_reset_n};
  end

  mdio_controller #(.INIT_PHY_ADDR(5'd2)) u_mdio0 (
    .s_axi_lite_clk (axis_clk), .s_axi_lite_resetn (axis_rst_n),
    .s_axi_awaddr (mdio0_s_axi_awaddr), .s_axi_awvalid (mdio0_s_axi_awvalid), .s_axi_awready (mdio0_s_axi_awready),
    .s_axi_wdata (mdio0_s_axi_wdata), .s_axi_wstrb (mdio0_s_axi_wstrb), .s_axi_wvalid (mdio0_s_axi_wvalid), .s_axi_wready (mdio0_s_axi_wready),
    .s_axi_bresp (mdio0_s_axi_bresp), .s_axi_bvalid (mdio0_s_axi_bvalid), .s_axi_bready (mdio0_s_axi_bready),
    .s_axi_araddr (mdio0_s_axi_araddr), .s_axi_arvalid (mdio0_s_axi_arvalid), .s_axi_arready (mdio0_s_axi_arready),
    .s_axi_rdata (mdio0_s_axi_rdata), .s_axi_rresp (mdio0_s_axi_rresp), .s_axi_rvalid (mdio0_s_axi_rvalid), .s_axi_rready (mdio0_s_axi_rready),
    .init_go_i (init_go0_sync[1]), .init_done_o (), .init_fail_o (),
    .phy_link_o (phy_link[0]), .phy_link_change_o (phy_link_chg[0]),
    .mdio_io (pl0_mdio), .mdc_o (pl0_mdc)
  );

  mdio_controller #(.INIT_PHY_ADDR(5'd3)) u_mdio1 (
    .s_axi_lite_clk (axis_clk), .s_axi_lite_resetn (axis_rst_n),
    .s_axi_awaddr (mdio1_s_axi_awaddr), .s_axi_awvalid (mdio1_s_axi_awvalid), .s_axi_awready (mdio1_s_axi_awready),
    .s_axi_wdata (mdio1_s_axi_wdata), .s_axi_wstrb (mdio1_s_axi_wstrb), .s_axi_wvalid (mdio1_s_axi_wvalid), .s_axi_wready (mdio1_s_axi_wready),
    .s_axi_bresp (mdio1_s_axi_bresp), .s_axi_bvalid (mdio1_s_axi_bvalid), .s_axi_bready (mdio1_s_axi_bready),
    .s_axi_araddr (mdio1_s_axi_araddr), .s_axi_arvalid (mdio1_s_axi_arvalid), .s_axi_arready (mdio1_s_axi_arready),
    .s_axi_rdata (mdio1_s_axi_rdata), .s_axi_rresp (mdio1_s_axi_rresp), .s_axi_rvalid (mdio1_s_axi_rvalid), .s_axi_rready (mdio1_s_axi_rready),
    .init_go_i (init_go1_sync[1]), .init_done_o (), .init_fail_o (),
    .phy_link_o (phy_link[1]), .phy_link_change_o (phy_link_chg[1]),
    .mdio_io (pl1_mdio), .mdc_o (pl1_mdc)
  );

  // ---------------------------------------------------------------------
  // SFP: GTH transceiver + PCS clocks
  // ---------------------------------------------------------------------
  logic [15:0] sfp_txdata, sfp_rxdata;
  logic [1:0]  sfp_txcharisk, sfp_rxcharisk, sfp_rxdisperr, sfp_rxnotintable;
  logic gth_usrclk, gth_usrclk_rst_n;
  logic gtx_clk_sfp, gtx_rst_n_sfp, gth_clk_sfp, gth_rst_n_sfp, sfp_mmcm_locked;
  logic sfp_gt_powergood, sfp_tx_resetdone, sfp_rx_resetdone;

  gth_sfp_wrapper u_gth (
    .freerun_clk_i (freerun_clk), .rst_n (ps_rst_n),
    .gtrefclk_p_i (sfp_refclk_p), .gtrefclk_n_i (sfp_refclk_n),
    .txp_o (sfp_txp), .txn_o (sfp_txn), .rxp_i (sfp_rxp), .rxn_i (sfp_rxn),
    .gth_clk_o (gth_usrclk), .gth_rst_n_o (gth_usrclk_rst_n),
    .txdata_i (sfp_txdata), .txcharisk_i (sfp_txcharisk),
    .rxdata_o (sfp_rxdata), .rxcharisk_o (sfp_rxcharisk),
    .rxdisperr_o (sfp_rxdisperr), .rxnotintable_o (sfp_rxnotintable),
    .gtpowergood_o (sfp_gt_powergood), .tx_resetdone_o (sfp_tx_resetdone), .rx_resetdone_o (sfp_rx_resetdone)
  );

  sfp_pcs_clk_gen u_sfp_clkgen (
    .gth_clk_i (gth_usrclk), .gth_rst_n_i (gth_usrclk_rst_n),
    .gtx_clk_o (gtx_clk_sfp), .gtx_rst_n_o (gtx_rst_n_sfp),
    .gth_clk_o (gth_clk_sfp), .gth_rst_n_o (gth_rst_n_sfp),
    .locked_o (sfp_mmcm_locked)
  );

  // TX_DISABLE is pulled up on the carrier (module off unless driven low);
  // sfp_sideband.sv drives it low only for a present, settled, fault-free module.
  sfp_sideband u_sfp_sideband (
    .clk (axis_clk), .rst_n (axis_rst_n),
    .mod_abs_i (sfp_mod_abs), .tx_fault_i (sfp_tx_fault), .los_i (sfp_los),
    .tx_disable_o (sfp_tx_disable),
    .force_disable_i (sfp_sb_force),
    .clr_fault_seen_i (sfp_sb_clr_fault), .clr_removed_seen_i (sfp_sb_clr_removed),
    .clr_lockout_i (sfp_sb_clr_lockout),
    .status_o (sfp_sb_status)
  );

  logic sfp_sync_ok, sfp_an_link_up, sfp_an_duplex_full, sfp_an_remote_fault;
  logic [1:0] sfp_an_pause;
  (* ASYNC_REG = "TRUE" *) logic [3:0] sfp_pcs_s1, sfp_pcs_s2;
  always_ff @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n) begin sfp_pcs_s1 <= 0; sfp_pcs_s2 <= 0; end
    else begin
      sfp_pcs_s1 <= {sfp_an_remote_fault, sfp_an_duplex_full, sfp_an_link_up, sfp_sync_ok};
      sfp_pcs_s2 <= sfp_pcs_s1;
    end
  end
  assign sfp_led = {sfp_sync_ok, sfp_an_link_up};

  // ---- link events for the CPU (axis_clk domain) ----
  // PHY link changes come from the MDIO controllers' PHYSTS poll (the PHY INT pad
  // is not wired to the FPGA). SFP sources are changes of already-debounced or
  // synchronized status.
  logic sfp_an_prev_q, sfp_abs_prev_q, sfp_los_prev_q, sfp_flt_prev_q;
  always_ff @(posedge axis_clk or negedge axis_rst_n) begin
    if (!axis_rst_n) begin
      sfp_an_prev_q <= 1'b0; sfp_abs_prev_q <= 1'b1; sfp_los_prev_q <= 1'b0; sfp_flt_prev_q <= 1'b0;
    end else begin
      sfp_an_prev_q  <= sfp_pcs_s2[1];   // link_up, already synchronized above (one synchronizer per source)
      sfp_abs_prev_q <= sfp_sb_status[0];
      sfp_los_prev_q <= sfp_sb_status[1];
      sfp_flt_prev_q <= sfp_sb_status[2];
    end
  end
  assign link_event_set = { !sfp_flt_prev_q && sfp_sb_status[2],
                            sfp_los_prev_q ^ sfp_sb_status[1],
                            sfp_abs_prev_q ^ sfp_sb_status[0],
                            sfp_an_prev_q  ^ sfp_pcs_s2[1],
                            phy_link_chg[1], phy_link_chg[0] };

  // GEM resets: each GEM FIFO clock domain gets its own synchronized reset
  logic gem0_rx_rst_n, gem0_tx_rst_n, gem1_rx_rst_n, gem1_tx_rst_n;
  rst_sync u_gem0_rx_rst (.clk (gem0_rx_clk), .arst_n_i (ps_rst_n), .rst_n_o (gem0_rx_rst_n));
  rst_sync u_gem0_tx_rst (.clk (gem0_tx_clk), .arst_n_i (ps_rst_n), .rst_n_o (gem0_tx_rst_n));
  rst_sync u_gem1_rx_rst (.clk (gem1_rx_clk), .arst_n_i (ps_rst_n), .rst_n_o (gem1_rx_rst_n));
  rst_sync u_gem1_tx_rst (.clk (gem1_tx_clk), .arst_n_i (ps_rst_n), .rst_n_o (gem1_tx_rst_n));

  // ---------------------------------------------------------------------
  // the switch
  // ---------------------------------------------------------------------
  switch_top #(
    .STATS_DDR(STATS_DDR),.STATS_DEBUG(STATS_DEBUG),
    // PCS clock is 125 MHz: 10 ms 1000BASE-X restart/acknowledge/idle timers.
    .SFP_AN_BREAK_LINK_CYCLES(1_250_000),
    .SFP_AN_LINK_TIMER_CYCLES(1_250_000),
    .SFP_AN_IDLE_DETECT_CYCLES(1_250_000)
  ) u_switch (
    .stats_request(stats_request),.stats_index(stats_index),.stats_ack(stats_ack),.stats_value(stats_value),
    .clk (fab_clk), .rst_n (fab_rst_n),
    .gtx_clk_pl0 (gtx_clk_pl0), .gtx_clk_pl1 (gtx_clk_pl1),
    .gtx_clk_sfp (gtx_clk_sfp), .gtx_rst_n_sfp (gtx_rst_n_sfp),
    .gth_clk_sfp (gth_clk_sfp), .gth_rst_n_sfp (gth_rst_n_sfp),
    .mac_clk_en (1'b1),
    .gem_rx_rst_n_ps0 (gem0_rx_rst_n), .gem_tx_rst_n_ps0 (gem0_tx_rst_n),
    .gem_rx_rst_n_ps1 (gem1_rx_rst_n), .gem_tx_rst_n_ps1 (gem1_tx_rst_n),
    .default_age_i (DEFAULT_AGE_RESET),
    .link_up_i (link_up_axi), .link_flush_tog_i (link_tog_axi), .link_flush_busy_o (link_flush_busy),
    .pl0_gmii_rxd (pl0_gmii_rxd), .pl0_gmii_rx_dv (pl0_gmii_rx_dv), .pl0_gmii_rx_er (pl0_gmii_rx_er),
    .pl0_gmii_txd (pl0_gmii_txd), .pl0_gmii_tx_en (pl0_gmii_tx_en), .pl0_gmii_tx_er (pl0_gmii_tx_er),
    .pl1_gmii_rxd (pl1_gmii_rxd), .pl1_gmii_rx_dv (pl1_gmii_rx_dv), .pl1_gmii_rx_er (pl1_gmii_rx_er),
    .pl1_gmii_txd (pl1_gmii_txd), .pl1_gmii_tx_en (pl1_gmii_tx_en), .pl1_gmii_tx_er (pl1_gmii_tx_er),
    .sfp_txdata_o (sfp_txdata), .sfp_txcharisk_o (sfp_txcharisk),
    .sfp_rxdata_i (sfp_rxdata), .sfp_rxcharisk_i (sfp_rxcharisk),
    .sfp_rxdisperr_i (sfp_rxdisperr), .sfp_rxnotintable_i (sfp_rxnotintable),
    .sfp_sync_ok_o (sfp_sync_ok), .sfp_an_link_up_o (sfp_an_link_up),
    .sfp_an_duplex_full_o (sfp_an_duplex_full), .sfp_an_pause_o (sfp_an_pause),
    .sfp_an_remote_fault_o (sfp_an_remote_fault),
    .axis_clk (axis_clk),
    .axis_rst_n (axis_rst_n),
    .gem_rx_clk_ps0 (gem0_rx_clk), .gem_tx_clk_ps0 (gem0_tx_clk),
    .gem_rx_clk_ps1 (gem1_rx_clk), .gem_tx_clk_ps1 (gem1_tx_clk),
    .gem0_rx_w_data_i (gem0_rx_w_data_i),
    .gem0_rx_w_wr_i (gem0_rx_w_wr_i),
    .gem0_rx_w_sop_i (gem0_rx_w_sop_i),
    .gem0_rx_w_eop_i (gem0_rx_w_eop_i),
    .gem0_rx_w_err_i (gem0_rx_w_err_i),
    .gem0_rx_w_flush_i (gem0_rx_w_flush_i),
    .gem0_rx_w_status_i (gem0_rx_w_status_i),
    .gem0_rx_w_overflow_o (gem0_rx_w_overflow_o),
    .gem0_rx_w_status_o (gem0_rx_w_status_o),
    .gem0_tx_r_rd_i (gem0_tx_r_rd_i),
    .gem0_tx_r_data_rdy_o (gem0_tx_r_data_rdy_o),
    .gem0_tx_r_valid_o (gem0_tx_r_valid_o),
    .gem0_tx_r_data_o (gem0_tx_r_data_o),
    .gem0_tx_r_sop_o (gem0_tx_r_sop_o),
    .gem0_tx_r_eop_o (gem0_tx_r_eop_o),
    .gem0_tx_r_err_o (gem0_tx_r_err_o),
    .gem0_tx_r_underflow_o (gem0_tx_r_underflow_o),
    .gem0_tx_r_flushed_o (gem0_tx_r_flushed_o),
    .gem0_tx_r_control_o (gem0_tx_r_control_o),
    .gem0_dma_tx_end_tog_i (gem0_dma_tx_end_tog_i),
    .gem0_dma_tx_status_tog_o (gem0_dma_tx_status_tog_o),
    .gem0_tx_r_status_i (gem0_tx_r_status_i),
    .gem1_rx_w_data_i (gem1_rx_w_data_i),
    .gem1_rx_w_wr_i (gem1_rx_w_wr_i),
    .gem1_rx_w_sop_i (gem1_rx_w_sop_i),
    .gem1_rx_w_eop_i (gem1_rx_w_eop_i),
    .gem1_rx_w_err_i (gem1_rx_w_err_i),
    .gem1_rx_w_flush_i (gem1_rx_w_flush_i),
    .gem1_rx_w_status_i (gem1_rx_w_status_i),
    .gem1_rx_w_overflow_o (gem1_rx_w_overflow_o),
    .gem1_rx_w_status_o (gem1_rx_w_status_o),
    .gem1_tx_r_rd_i (gem1_tx_r_rd_i),
    .gem1_tx_r_data_rdy_o (gem1_tx_r_data_rdy_o),
    .gem1_tx_r_valid_o (gem1_tx_r_valid_o),
    .gem1_tx_r_data_o (gem1_tx_r_data_o),
    .gem1_tx_r_sop_o (gem1_tx_r_sop_o),
    .gem1_tx_r_eop_o (gem1_tx_r_eop_o),
    .gem1_tx_r_err_o (gem1_tx_r_err_o),
    .gem1_tx_r_underflow_o (gem1_tx_r_underflow_o),
    .gem1_tx_r_flushed_o (gem1_tx_r_flushed_o),
    .gem1_tx_r_control_o (gem1_tx_r_control_o),
    .gem1_dma_tx_end_tog_i (gem1_dma_tx_end_tog_i),
    .gem1_dma_tx_status_tog_o (gem1_dma_tx_status_tog_o),
    .gem1_tx_r_status_i (gem1_tx_r_status_i),
    .pl0_s_axi_awaddr (pl0_s_axi_awaddr),
    .pl0_s_axi_awvalid (pl0_s_axi_awvalid),
    .pl0_s_axi_awready (pl0_s_axi_awready),
    .pl0_s_axi_wdata (pl0_s_axi_wdata),
    .pl0_s_axi_wstrb (pl0_s_axi_wstrb),
    .pl0_s_axi_wvalid (pl0_s_axi_wvalid),
    .pl0_s_axi_wready (pl0_s_axi_wready),
    .pl0_s_axi_bresp (pl0_s_axi_bresp),
    .pl0_s_axi_bvalid (pl0_s_axi_bvalid),
    .pl0_s_axi_bready (pl0_s_axi_bready),
    .pl0_s_axi_araddr (pl0_s_axi_araddr),
    .pl0_s_axi_arvalid (pl0_s_axi_arvalid),
    .pl0_s_axi_arready (pl0_s_axi_arready),
    .pl0_s_axi_rdata (pl0_s_axi_rdata),
    .pl0_s_axi_rresp (pl0_s_axi_rresp),
    .pl0_s_axi_rvalid (pl0_s_axi_rvalid),
    .pl0_s_axi_rready (pl0_s_axi_rready),
    .pl0_interrupt (pl0_interrupt),
    .pl0_mac_irq (pl0_mac_irq),
    .pl1_s_axi_awaddr (pl1_s_axi_awaddr),
    .pl1_s_axi_awvalid (pl1_s_axi_awvalid),
    .pl1_s_axi_awready (pl1_s_axi_awready),
    .pl1_s_axi_wdata (pl1_s_axi_wdata),
    .pl1_s_axi_wstrb (pl1_s_axi_wstrb),
    .pl1_s_axi_wvalid (pl1_s_axi_wvalid),
    .pl1_s_axi_wready (pl1_s_axi_wready),
    .pl1_s_axi_bresp (pl1_s_axi_bresp),
    .pl1_s_axi_bvalid (pl1_s_axi_bvalid),
    .pl1_s_axi_bready (pl1_s_axi_bready),
    .pl1_s_axi_araddr (pl1_s_axi_araddr),
    .pl1_s_axi_arvalid (pl1_s_axi_arvalid),
    .pl1_s_axi_arready (pl1_s_axi_arready),
    .pl1_s_axi_rdata (pl1_s_axi_rdata),
    .pl1_s_axi_rresp (pl1_s_axi_rresp),
    .pl1_s_axi_rvalid (pl1_s_axi_rvalid),
    .pl1_s_axi_rready (pl1_s_axi_rready),
    .pl1_interrupt (pl1_interrupt),
    .pl1_mac_irq (pl1_mac_irq),
    .sfp_s_axi_awaddr (sfp_s_axi_awaddr),
    .sfp_s_axi_awvalid (sfp_s_axi_awvalid),
    .sfp_s_axi_awready (sfp_s_axi_awready),
    .sfp_s_axi_wdata (sfp_s_axi_wdata),
    .sfp_s_axi_wstrb (sfp_s_axi_wstrb),
    .sfp_s_axi_wvalid (sfp_s_axi_wvalid),
    .sfp_s_axi_wready (sfp_s_axi_wready),
    .sfp_s_axi_bresp (sfp_s_axi_bresp),
    .sfp_s_axi_bvalid (sfp_s_axi_bvalid),
    .sfp_s_axi_bready (sfp_s_axi_bready),
    .sfp_s_axi_araddr (sfp_s_axi_araddr),
    .sfp_s_axi_arvalid (sfp_s_axi_arvalid),
    .sfp_s_axi_arready (sfp_s_axi_arready),
    .sfp_s_axi_rdata (sfp_s_axi_rdata),
    .sfp_s_axi_rresp (sfp_s_axi_rresp),
    .sfp_s_axi_rvalid (sfp_s_axi_rvalid),
    .sfp_s_axi_rready (sfp_s_axi_rready),
    .sfp_interrupt (sfp_interrupt),
    .sfp_mac_irq (sfp_mac_irq),
    .cpu_s_axis_tdata (cpu_s_axis_tdata),
    .cpu_s_axis_tkeep (cpu_s_axis_tkeep),
    .cpu_s_axis_tvalid (cpu_s_axis_tvalid),
    .cpu_s_axis_tlast (cpu_s_axis_tlast),
    .cpu_s_axis_tready (cpu_s_axis_tready),
    .cpu_m_axis_tdata (cpu_m_axis_tdata),
    .cpu_m_axis_tkeep (cpu_m_axis_tkeep),
    .cpu_m_axis_tvalid (cpu_m_axis_tvalid),
    .cpu_m_axis_tlast (cpu_m_axis_tlast),
    .cpu_m_axis_tready (cpu_m_axis_tready),
    .m_axi_ing_awid (m_axi_ing_awid),
    .m_axi_ing_awaddr (m_axi_ing_awaddr),
    .m_axi_ing_awlen (m_axi_ing_awlen),
    .m_axi_ing_awsize (m_axi_ing_awsize),
    .m_axi_ing_awburst (m_axi_ing_awburst),
    .m_axi_ing_awvalid (m_axi_ing_awvalid),
    .m_axi_ing_awready (m_axi_ing_awready),
    .m_axi_ing_wdata (m_axi_ing_wdata),
    .m_axi_ing_wstrb (m_axi_ing_wstrb),
    .m_axi_ing_wlast (m_axi_ing_wlast),
    .m_axi_ing_wvalid (m_axi_ing_wvalid),
    .m_axi_ing_wready (m_axi_ing_wready),
    .m_axi_ing_bid (m_axi_ing_bid),
    .m_axi_ing_bresp (m_axi_ing_bresp),
    .m_axi_ing_bvalid (m_axi_ing_bvalid),
    .m_axi_ing_bready (m_axi_ing_bready),
    .m_axi_egr_arid (m_axi_egr_arid),
    .m_axi_egr_araddr (m_axi_egr_araddr),
    .m_axi_egr_arlen (m_axi_egr_arlen),
    .m_axi_egr_arsize (m_axi_egr_arsize),
    .m_axi_egr_arburst (m_axi_egr_arburst),
    .m_axi_egr_arvalid (m_axi_egr_arvalid),
    .m_axi_egr_arready (m_axi_egr_arready),
    .m_axi_egr_rid (m_axi_egr_rid),
    .m_axi_egr_rdata (m_axi_egr_rdata),
    .m_axi_egr_rresp (m_axi_egr_rresp),
    .m_axi_egr_rlast (m_axi_egr_rlast),
    .m_axi_egr_rvalid (m_axi_egr_rvalid),
    .m_axi_egr_rready (m_axi_egr_rready),
    .m_axi_cpu_awid (m_axi_cpu_awid),
    .m_axi_cpu_awaddr (m_axi_cpu_awaddr),
    .m_axi_cpu_awlen (m_axi_cpu_awlen),
    .m_axi_cpu_awsize (m_axi_cpu_awsize),
    .m_axi_cpu_awburst (m_axi_cpu_awburst),
    .m_axi_cpu_awvalid (m_axi_cpu_awvalid),
    .m_axi_cpu_awready (m_axi_cpu_awready),
    .m_axi_cpu_wdata (m_axi_cpu_wdata),
    .m_axi_cpu_wstrb (m_axi_cpu_wstrb),
    .m_axi_cpu_wlast (m_axi_cpu_wlast),
    .m_axi_cpu_wvalid (m_axi_cpu_wvalid),
    .m_axi_cpu_wready (m_axi_cpu_wready),
    .m_axi_cpu_bid (m_axi_cpu_bid),
    .m_axi_cpu_bresp (m_axi_cpu_bresp),
    .m_axi_cpu_bvalid (m_axi_cpu_bvalid),
    .m_axi_cpu_bready (m_axi_cpu_bready),
    .m_axi_cpu_arid (m_axi_cpu_arid),
    .m_axi_cpu_araddr (m_axi_cpu_araddr),
    .m_axi_cpu_arlen (m_axi_cpu_arlen),
    .m_axi_cpu_arsize (m_axi_cpu_arsize),
    .m_axi_cpu_arburst (m_axi_cpu_arburst),
    .m_axi_cpu_arvalid (m_axi_cpu_arvalid),
    .m_axi_cpu_arready (m_axi_cpu_arready),
    .m_axi_cpu_rid (m_axi_cpu_rid),
    .m_axi_cpu_rdata (m_axi_cpu_rdata),
    .m_axi_cpu_rresp (m_axi_cpu_rresp),
    .m_axi_cpu_rlast (m_axi_cpu_rlast),
    .m_axi_cpu_rvalid (m_axi_cpu_rvalid),
    .m_axi_cpu_rready (m_axi_cpu_rready)
  );

endmodule
