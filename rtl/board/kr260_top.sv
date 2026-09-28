// Board glue: production catalog BD beside the physical Ethernet shell.
module kr260_top (
  input  wire pl0_ref_clk_25m,
  output wire [3:0] pl0_rgmii_txd,
  output wire pl0_rgmii_tx_ctl,
  output wire pl0_rgmii_txc,
  input  wire [3:0] pl0_rgmii_rxd,
  input  wire pl0_rgmii_rx_ctl,
  input  wire pl0_rgmii_rxc,
  inout  wire pl0_mdio,
  output wire pl0_mdc,
  output wire pl0_phy_reset_n,
  input  wire pl1_ref_clk_25m,
  output wire [3:0] pl1_rgmii_txd,
  output wire pl1_rgmii_tx_ctl,
  output wire pl1_rgmii_txc,
  input  wire [3:0] pl1_rgmii_rxd,
  input  wire pl1_rgmii_rx_ctl,
  input  wire pl1_rgmii_rxc,
  inout  wire pl1_mdio,
  output wire pl1_mdc,
  output wire pl1_phy_reset_n,
  input  wire sfp_refclk_p,
  input  wire sfp_refclk_n,
  output wire sfp_txp,
  output wire sfp_txn,
  input  wire sfp_rxp,
  input  wire sfp_rxn,
  input  wire sfp_los,
  input  wire sfp_mod_abs,
  input  wire sfp_tx_fault,
  output wire sfp_tx_disable,
  output wire [1:0] sfp_led,
  inout  wire sfp_iic_scl_io,
  inout  wire sfp_iic_sda_io
);
  wire  ps_rst_n;
  wire  freerun_clk;
  wire  fabric_clk_o;
  wire  fabric_rst_n_o;
  wire  axis_clk;
  wire  axis_rst_n;
  wire  gem0_rx_clk;
  wire  gem0_tx_clk;
  wire  gem1_rx_clk;
  wire  gem1_tx_clk;
  wire  gem0_rx_rst_n;
  wire  gem0_tx_rst_n;
  wire  gem1_rx_rst_n;
  wire  gem1_tx_rst_n;
  wire  gtx_clk_pl0;
  wire [2:0] pl0_port_mode;
  wire pl0_rx_byte_ce, pl0_tx_byte_ce;
  wire [7:0] pl0_gmii_rxd;
  wire  pl0_gmii_rx_dv;
  wire  pl0_gmii_rx_er;
  wire [7:0] pl0_gmii_txd;
  wire  pl0_gmii_tx_en;
  wire  pl0_gmii_tx_er;
  wire  gtx_clk_pl1;
  wire [2:0] pl1_port_mode;
  wire pl1_rx_byte_ce, pl1_tx_byte_ce;
  wire [7:0] pl1_gmii_rxd;
  wire  pl1_gmii_rx_dv;
  wire  pl1_gmii_rx_er;
  wire [7:0] pl1_gmii_txd;
  wire  pl1_gmii_tx_en;
  wire  pl1_gmii_tx_er;
  wire  gtx_clk_sfp;
  wire  gtx_rst_n_sfp;
  wire  gth_clk_sfp;
  wire  gth_rst_n_sfp;
`ifdef KR260_SFP_10G
  wire [63:0] sfp_txdata;
`else
  wire [15:0] sfp_txdata;
`endif
  wire [1:0] sfp_txcharisk;
`ifdef KR260_SFP_10G
  wire [63:0] sfp_rxdata;
`else
  wire [15:0] sfp_rxdata;
`endif
  wire [1:0] sfp_rxcharisk;
  wire [1:0] sfp_rxdisperr;
  wire [1:0] sfp_rxnotintable;
`ifdef KR260_SFP_10G
  wire sfp_rx_bitslip,sfp_rx_reset_req;
`endif
`ifdef KR260_SFP_DUAL
  wire sfp_gmii_clk,sfp_gmii_rst_n,sfp_pcs1g_clk,sfp_pcs1g_rst_n,sfp_gt_mode,sfp_gt_ready,sfp_gt_error,sfp_gt_request,sfp_gt_retry;
`endif
  wire  sfp_sync_ok;
  wire  sfp_an_link_up;
  wire  sfp_an_duplex_full;
  wire  sfp_an_remote_fault;
  wire [3:0] diag_flags;
  wire [1:0] idelay_rdy_axi;
  wire [3:0] diag_clr;
  wire [1:0] phy_link_chg;
  wire [5:0] link_event_set;
  wire [15:0] sfp_sb_status;
  wire [3:0] sfp_pcs_s2;
  wire  sfp_sb_force;
  wire  sfp_sb_clr_fault;
  wire  sfp_sb_clr_removed;
  wire  sfp_sb_clr_lockout;

  system_wrapper u_bd (
    .pl0_mdio(pl0_mdio), .pl0_mdc(pl0_mdc),
    .pl0_phy_ready(pl0_phy_reset_n),
    .pl1_mdio(pl1_mdio), .pl1_mdc(pl1_mdc),
    .pl1_phy_ready(pl1_phy_reset_n),

    .ps_rst_n(ps_rst_n),
    .freerun_clk(freerun_clk),
    .fabric_clk_o(fabric_clk_o),
    .fabric_rst_n_o(fabric_rst_n_o),
    .axis_clk(axis_clk),
    .axis_rst_n(axis_rst_n),
    .gem0_rx_clk(gem0_rx_clk),
    .gem0_tx_clk(gem0_tx_clk),
    .gem1_rx_clk(gem1_rx_clk),
    .gem1_tx_clk(gem1_tx_clk),
    .gem0_rx_rst_n(gem0_rx_rst_n),
    .gem0_tx_rst_n(gem0_tx_rst_n),
    .gem1_rx_rst_n(gem1_rx_rst_n),
    .gem1_tx_rst_n(gem1_tx_rst_n),
    .gtx_clk_pl0(gtx_clk_pl0),
    .pl0_port_mode(pl0_port_mode),
    .pl0_rx_byte_ce(pl0_rx_byte_ce), .pl0_tx_byte_ce(pl0_tx_byte_ce),
    .pl0_gmii_rxd(pl0_gmii_rxd),
    .pl0_gmii_rx_dv(pl0_gmii_rx_dv),
    .pl0_gmii_rx_er(pl0_gmii_rx_er),
    .pl0_gmii_txd(pl0_gmii_txd),
    .pl0_gmii_tx_en(pl0_gmii_tx_en),
    .pl0_gmii_tx_er(pl0_gmii_tx_er),
    .gtx_clk_pl1(gtx_clk_pl1),
    .pl1_port_mode(pl1_port_mode),
    .pl1_rx_byte_ce(pl1_rx_byte_ce), .pl1_tx_byte_ce(pl1_tx_byte_ce),
    .pl1_gmii_rxd(pl1_gmii_rxd),
    .pl1_gmii_rx_dv(pl1_gmii_rx_dv),
    .pl1_gmii_rx_er(pl1_gmii_rx_er),
    .pl1_gmii_txd(pl1_gmii_txd),
    .pl1_gmii_tx_en(pl1_gmii_tx_en),
    .pl1_gmii_tx_er(pl1_gmii_tx_er),
    .gtx_clk_sfp(gtx_clk_sfp),
    .gtx_rst_n_sfp(gtx_rst_n_sfp),
    .gth_clk_sfp(gth_clk_sfp),
    .gth_rst_n_sfp(gth_rst_n_sfp),
`ifdef KR260_SFP_10G
    .sfp_rx_bitslip(sfp_rx_bitslip),.sfp_rx_reset_req(sfp_rx_reset_req),
`ifdef KR260_SFP_DUAL
    .sfp_gmii_clk(sfp_gmii_clk),
    .sfp_gmii_rst_n(sfp_gmii_rst_n),
    .sfp_pcs1g_clk(sfp_pcs1g_clk),
    .sfp_pcs1g_rst_n(sfp_pcs1g_rst_n),
    .sfp_gt_mode(sfp_gt_mode),
    .sfp_gt_ready(sfp_gt_ready),
    .sfp_gt_error(sfp_gt_error),
    .sfp_gt_request(sfp_gt_request),
    .sfp_gt_retry(sfp_gt_retry),
`endif
`endif
    .sfp_txdata(sfp_txdata),
    .sfp_txcharisk(sfp_txcharisk),
    .sfp_rxdata(sfp_rxdata),
    .sfp_rxcharisk(sfp_rxcharisk),
    .sfp_rxdisperr(sfp_rxdisperr),
    .sfp_rxnotintable(sfp_rxnotintable),
    .sfp_sync_ok(sfp_sync_ok),
    .sfp_an_link_up(sfp_an_link_up),
    .sfp_an_duplex_full(sfp_an_duplex_full),
    .sfp_an_remote_fault(sfp_an_remote_fault),
    .diag_flags(diag_flags),
    .idelay_rdy_axi(idelay_rdy_axi),
    .diag_clr(diag_clr),
    .phy_link_chg(phy_link_chg),
    .link_event_set(link_event_set),
    .sfp_sb_status(sfp_sb_status),
    .sfp_pcs_s2(sfp_pcs_s2),
    .sfp_sb_force(sfp_sb_force),
    .sfp_sb_clr_fault(sfp_sb_clr_fault),
    .sfp_sb_clr_removed(sfp_sb_clr_removed),
    .sfp_sb_clr_lockout(sfp_sb_clr_lockout),
    .sfp_iic_scl_io(sfp_iic_scl_io),
    .sfp_iic_sda_io(sfp_iic_sda_io)
  );

  kr260_pl_top u_pl (
    .ps_rst_n(ps_rst_n),
    .freerun_clk(freerun_clk),
    .fabric_clk_o(fabric_clk_o),
    .fabric_rst_n_o(fabric_rst_n_o),
    .pl0_ref_clk_25m(pl0_ref_clk_25m),
    .pl0_rgmii_txd(pl0_rgmii_txd),
    .pl0_rgmii_tx_ctl(pl0_rgmii_tx_ctl),
    .pl0_rgmii_txc(pl0_rgmii_txc),
    .pl0_rgmii_rxd(pl0_rgmii_rxd),
    .pl0_rgmii_rx_ctl(pl0_rgmii_rx_ctl),
    .pl0_rgmii_rxc(pl0_rgmii_rxc),
    .pl0_phy_reset_n(pl0_phy_reset_n),
    .pl1_ref_clk_25m(pl1_ref_clk_25m),
    .pl1_rgmii_txd(pl1_rgmii_txd),
    .pl1_rgmii_tx_ctl(pl1_rgmii_tx_ctl),
    .pl1_rgmii_txc(pl1_rgmii_txc),
    .pl1_rgmii_rxd(pl1_rgmii_rxd),
    .pl1_rgmii_rx_ctl(pl1_rgmii_rx_ctl),
    .pl1_rgmii_rxc(pl1_rgmii_rxc),
    .pl1_phy_reset_n(pl1_phy_reset_n),
    .sfp_refclk_p(sfp_refclk_p),
    .sfp_refclk_n(sfp_refclk_n),
    .sfp_txp(sfp_txp),
    .sfp_txn(sfp_txn),
    .sfp_rxp(sfp_rxp),
    .sfp_rxn(sfp_rxn),
    .sfp_los(sfp_los),
    .sfp_mod_abs(sfp_mod_abs),
    .sfp_tx_fault(sfp_tx_fault),
    .sfp_tx_disable(sfp_tx_disable),
    .sfp_led(sfp_led),
    .axis_clk(axis_clk),
    .axis_rst_n(axis_rst_n),
    .gem0_rx_clk(gem0_rx_clk),
    .gem0_tx_clk(gem0_tx_clk),
    .gem1_rx_clk(gem1_rx_clk),
    .gem1_tx_clk(gem1_tx_clk),
    .gem0_rx_rst_n(gem0_rx_rst_n),
    .gem0_tx_rst_n(gem0_tx_rst_n),
    .gem1_rx_rst_n(gem1_rx_rst_n),
    .gem1_tx_rst_n(gem1_tx_rst_n),
    .gtx_clk_pl0(gtx_clk_pl0),
    .pl0_port_mode(pl0_port_mode),
    .pl0_rx_byte_ce(pl0_rx_byte_ce), .pl0_tx_byte_ce(pl0_tx_byte_ce),
    .pl0_gmii_rxd(pl0_gmii_rxd),
    .pl0_gmii_rx_dv(pl0_gmii_rx_dv),
    .pl0_gmii_rx_er(pl0_gmii_rx_er),
    .pl0_gmii_txd(pl0_gmii_txd),
    .pl0_gmii_tx_en(pl0_gmii_tx_en),
    .pl0_gmii_tx_er(pl0_gmii_tx_er),
    .gtx_clk_pl1(gtx_clk_pl1),
    .pl1_port_mode(pl1_port_mode),
    .pl1_rx_byte_ce(pl1_rx_byte_ce), .pl1_tx_byte_ce(pl1_tx_byte_ce),
    .pl1_gmii_rxd(pl1_gmii_rxd),
    .pl1_gmii_rx_dv(pl1_gmii_rx_dv),
    .pl1_gmii_rx_er(pl1_gmii_rx_er),
    .pl1_gmii_txd(pl1_gmii_txd),
    .pl1_gmii_tx_en(pl1_gmii_tx_en),
    .pl1_gmii_tx_er(pl1_gmii_tx_er),
    .gtx_clk_sfp(gtx_clk_sfp),
    .gtx_rst_n_sfp(gtx_rst_n_sfp),
    .gth_clk_sfp(gth_clk_sfp),
    .gth_rst_n_sfp(gth_rst_n_sfp),
`ifdef KR260_SFP_10G
    .sfp_rx_bitslip(sfp_rx_bitslip),.sfp_rx_reset_req(sfp_rx_reset_req),
`ifdef KR260_SFP_DUAL
    .sfp_gmii_clk(sfp_gmii_clk),
    .sfp_gmii_rst_n(sfp_gmii_rst_n),
    .sfp_pcs1g_clk(sfp_pcs1g_clk),
    .sfp_pcs1g_rst_n(sfp_pcs1g_rst_n),
    .sfp_gt_mode(sfp_gt_mode),
    .sfp_gt_ready(sfp_gt_ready),
    .sfp_gt_error(sfp_gt_error),
    .sfp_gt_request(sfp_gt_request),
    .sfp_gt_retry(sfp_gt_retry),
`endif
`endif
    .sfp_txdata(sfp_txdata),
    .sfp_txcharisk(sfp_txcharisk),
    .sfp_rxdata(sfp_rxdata),
    .sfp_rxcharisk(sfp_rxcharisk),
    .sfp_rxdisperr(sfp_rxdisperr),
    .sfp_rxnotintable(sfp_rxnotintable),
    .sfp_sync_ok(sfp_sync_ok),
    .sfp_an_link_up(sfp_an_link_up),
    .sfp_an_duplex_full(sfp_an_duplex_full),
    .sfp_an_remote_fault(sfp_an_remote_fault),
    .diag_flags(diag_flags),
    .idelay_rdy_axi(idelay_rdy_axi),
    .diag_clr(diag_clr),
    .phy_link_chg(phy_link_chg),
    .link_event_set(link_event_set),
    .sfp_sb_status(sfp_sb_status),
    .sfp_pcs_s2(sfp_pcs_s2),
    .sfp_sb_force(sfp_sb_force),
    .sfp_sb_clr_fault(sfp_sb_clr_fault),
    .sfp_sb_clr_removed(sfp_sb_clr_removed),
    .sfp_sb_clr_lockout(sfp_sb_clr_lockout)
  );
endmodule
