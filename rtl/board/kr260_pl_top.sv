// KR260 physical shell. Digital endpoints, fabric and management live in system.bd.
// Keep u_pl and physical instance names stable for board timing constraints.
module kr260_pl_top (
  input wire  ps_rst_n,
  input wire  freerun_clk,
  output wire  fabric_clk_o,
  output wire  fabric_rst_n_o,
  input wire  pl0_ref_clk_25m,
  output wire [3:0] pl0_rgmii_txd,
  output wire  pl0_rgmii_tx_ctl,
  output wire  pl0_rgmii_txc,
  input wire [3:0] pl0_rgmii_rxd,
  input wire  pl0_rgmii_rx_ctl,
  input wire  pl0_rgmii_rxc,
  output wire  pl0_phy_reset_n,
  input wire  pl1_ref_clk_25m,
  output wire [3:0] pl1_rgmii_txd,
  output wire  pl1_rgmii_tx_ctl,
  output wire  pl1_rgmii_txc,
  input wire [3:0] pl1_rgmii_rxd,
  input wire  pl1_rgmii_rx_ctl,
  input wire  pl1_rgmii_rxc,
  output wire  pl1_phy_reset_n,
  input wire  sfp_refclk_p,
  input wire  sfp_refclk_n,
  output wire  sfp_txp,
  output wire  sfp_txn,
  input wire  sfp_rxp,
  input wire  sfp_rxn,
  input wire  sfp_los,
  input wire  sfp_mod_abs,
  input wire  sfp_tx_fault,
  output wire  sfp_tx_disable,
  output wire [1:0] sfp_led,
  input wire  axis_clk,
  input wire  axis_rst_n,
  input wire  gem0_rx_clk,
  input wire  gem0_tx_clk,
  input wire  gem1_rx_clk,
  input wire  gem1_tx_clk,
  output wire  gem0_rx_rst_n,
  output wire  gem0_tx_rst_n,
  output wire  gem1_rx_rst_n,
  output wire  gem1_tx_rst_n,
  output wire  gtx_clk_pl0,
  input wire [2:0] pl0_port_mode,
  output wire pl0_rx_byte_ce, pl0_tx_byte_ce,
  output wire [7:0] pl0_gmii_rxd,
  output wire  pl0_gmii_rx_dv,
  output wire  pl0_gmii_rx_er,
  input wire [7:0] pl0_gmii_txd,
  input wire  pl0_gmii_tx_en,
  input wire  pl0_gmii_tx_er,
  output wire  gtx_clk_pl1,
  input wire [2:0] pl1_port_mode,
  output wire pl1_rx_byte_ce, pl1_tx_byte_ce,
  output wire [7:0] pl1_gmii_rxd,
  output wire  pl1_gmii_rx_dv,
  output wire  pl1_gmii_rx_er,
  input wire [7:0] pl1_gmii_txd,
  input wire  pl1_gmii_tx_en,
  input wire  pl1_gmii_tx_er,
  output wire  gtx_clk_sfp,
  output wire  gtx_rst_n_sfp,
  output wire  gth_clk_sfp,
  output wire  gth_rst_n_sfp,
  input wire [15:0] sfp_txdata,
  input wire [1:0] sfp_txcharisk,
  output wire [15:0] sfp_rxdata,
  output wire [1:0] sfp_rxcharisk,
  output wire [1:0] sfp_rxdisperr,
  output wire [1:0] sfp_rxnotintable,
  input wire  sfp_sync_ok,
  input wire  sfp_an_link_up,
  input wire  sfp_an_duplex_full,
  input wire  sfp_an_remote_fault,
  output wire [3:0] diag_flags,
  (* ASYNC_REG = "TRUE" *) output logic [1:0] idelay_rdy_axi,
  input wire [3:0] diag_clr,
  input wire [1:0] phy_link_chg,
  output wire [5:0] link_event_set,
  output wire [15:0] sfp_sb_status,
  (* ASYNC_REG = "TRUE" *) output logic [3:0] sfp_pcs_s2,
  input wire  sfp_sb_force,
  input wire  sfp_sb_clr_fault,
  input wire  sfp_sb_clr_removed,
  input wire  sfp_sb_clr_lockout
);

  // ---------------------------------------------------------------------
  // PL0/PL1 clock generation (25 MHz -> 125/300/125 MHz each)
  // ---------------------------------------------------------------------
  wire fab_clk, fab_rst_n;
  logic gtx_rst_n_pl0, idly_clk_pl0, idly_rst_n_pl0, lock_pl0;
  logic gtx_rst_n_pl1, idly_clk_pl1, idly_rst_n_pl1, unused_clk_pl1, unused_rst_pl1, lock_pl1;

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

  logic [1:0] idelay_rdy_raw;
  (* ASYNC_REG = "TRUE" *) logic [1:0] idelay_rdy_s1;
  always_ff @(posedge axis_clk) begin
    idelay_rdy_s1  <= idelay_rdy_raw;
    idelay_rdy_axi <= idelay_rdy_s1;
  end

  // RX data IDELAY per port: chosen from routed setup/hold slack (PL0: 0.67/0.22 ns at 500 ps,
  // PL1: 0.94/-0.23 ns at 500 ps, then 0.21/0.70 at 1000 ps -> 750 ps) so each port window is roughly centred; re-tune after
  // large placement changes
  rgmii_gmii_adapter #(.RX_DATA_IDELAY_PS(700)) u_rgmii0 (
    .gtx_clk (gtx_clk_pl0), .gtx_rst_n (gtx_rst_n_pl0),
    .port_mode_i(pl0_port_mode), .rx_byte_ce_o(pl0_rx_byte_ce), .tx_byte_ce_o(pl0_tx_byte_ce),
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
    .port_mode_i(pl1_port_mode), .rx_byte_ce_o(pl1_rx_byte_ce), .tx_byte_ce_o(pl1_tx_byte_ce),
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
  // SFP: GTH transceiver + PCS clocks
  // ---------------------------------------------------------------------

  logic gth_usrclk, gth_usrclk_rst_n;
  logic sfp_mmcm_locked;
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

  (* ASYNC_REG = "TRUE" *) logic [3:0] sfp_pcs_s1;
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

  rst_sync u_gem0_rx_rst (.clk (gem0_rx_clk), .arst_n_i (ps_rst_n), .rst_n_o (gem0_rx_rst_n));
  rst_sync u_gem0_tx_rst (.clk (gem0_tx_clk), .arst_n_i (ps_rst_n), .rst_n_o (gem0_tx_rst_n));
  rst_sync u_gem1_rx_rst (.clk (gem1_rx_clk), .arst_n_i (ps_rst_n), .rst_n_o (gem1_rx_rst_n));
  rst_sync u_gem1_tx_rst (.clk (gem1_tx_clk), .arst_n_i (ps_rst_n), .rst_n_o (gem1_tx_rst_n));

endmodule
