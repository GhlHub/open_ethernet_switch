// gth_sfp_wrapper.sv
//
// The actual GTHE4_CHANNEL transceiver for the KR260's SFP cage --
// synthesis-only (not simulatable by Icarus/Verilator; see
// gth_sfp_sim_model.sv for the behavioral stand-in used everywhere this
// project's own testbenches exercise the SFP path). Wraps
// rtl/sfp_pcs/ip/gth_sfp_ip.xci, a Vivado gtwizard_ultrascale (v1.7) IP
// core, generated and validated against xck26-sfvc784-2LV-c by actually
// running Vivado's Transceiver Wizard rather than hand-writing
// GTHE4_CHANNEL's own ~100+ parameters from memory -- exactly the risk
// sfp_1000base_x_pcs.sv's original header flagged ("its ~100+ parameters
// need cross-checking against Vivado's own Transceiver Wizard output for
// the target part"). Regenerate rtl/sfp_pcs/ip/gth_sfp_ip.xci's output
// products in Vivado (Tools -> Generate Output Products) before
// synthesis/simulation of this file; only the .xci itself is meant to be
// checked in.
//
// Key finding from actually running the wizard (not assumed): at 1.25
// Gbps line rate / 8b10b on this part, GTHE4_CHANNEL rejects an 8-bit
// (1 code group/cycle) user-data width outright -- minimum is 16-bit (2
// code groups/cycle) at 62.5 MHz. sfp_1000base_x_pcs.sv's GTH-parallel-
// interface boundary was widened to match this native width/rate (see
// its own header) rather than carrying an adapter here.
//
// IP configuration highlights (see rtl/sfp_pcs/ip/gth_sfp_ip.xci for the
// authoritative, tool-validated full parameter set):
//   - GTH_TYPE=GTH, channel X0Y4 (KR260 SFP transceiver channel/quad
//     LOC is a carrier-board-schematic fact this project doesn't have
//     on hand -- X0Y4 is a placeholder that must be confirmed against
//     the actual KR260 carrier board TRM/schematic before implementation;
//     update CHANNEL_ENABLE/TX_MASTER_CHANNEL/RX_MASTER_CHANNEL in the
//     .xci together with this file's IBUFDS_GTE4/gth_sfp_ip instance
//     location constraints if it differs)
//   - CPLL (not QPLL), 125 MHz reference clock -- also a placeholder:
//     the KR260 SFP cage's actual reference clock frequency is another
//     carrier-board-schematic fact not available here; a different
//     refclk frequency needs a re-run of the wizard (CPLL multiplier
//     values are frequency-specific), not just a parameter edit
//   - 8b10b enabled both directions, hardware comma align enabled both
//     polarities (RXCOMMADETEN/RXMCOMMAALIGNEN/RXPCOMMAALIGNEN) --
//     matches sfp_1000base_x_pcs.sv's own documented tolerance for comma
//     arriving at either running-disparity polarity
//   - RX elastic buffer enabled (not bypassed) + ENABLE_COMMON_USRCLK,
//     so the IP's own TX-side user clock also drives the RX fabric
//     interface -- the buffer absorbs the real PPM offset between local
//     and recovered clocks internally, so this wrapper only needs to
//     hand the rest of the design ONE clock domain (gth_clk_o) for both
//     TX and RX, matching what sfp_1000base_x_pcs.sv's gearbox/degearbox
//     assumes. This is the standard, intended use of this feature (not
//     a simulation-only simplification) -- real per-symbol clock
//     recovery still happens in the CDR ahead of the elastic buffer.
//   - reset sequencing (PLL cal, TX/RX PLL+datapath resets, waiting for
//     resetdone) is handled entirely inside the generated IP
//     (LOCATE_RESET_CONTROLLER=CORE) -- this wrapper only needs to
//     synchronize one external reset into gtwiz_reset_all_in and wait
//     for gtwiz_reset_tx/rx_done_out, not hand-sequence GT resets itself

module gth_sfp_wrapper (
  input  logic freerun_clk_i, // 50 MHz, always-on, independent of GT
                                // lock/reset state (drives the IP's
                                // internal reset controller + DRP)
  input  logic rst_n,          // async system reset in

  // SFP cage MGT reference clock (differential pins)
  input  logic gtrefclk_p_i,
  input  logic gtrefclk_n_i,

  // SFP cage serial data pins
  output logic txp_o,
  output logic txn_o,
  input  logic rxp_i,
  input  logic rxn_i,

  // GTH-parallel-interface clock this wrapper generates (62.5 MHz-class,
  // shared by TX and RX -- see header) and its reset, synchronized to it
  output logic gth_clk_o,
  output logic gth_rst_n_o,

  // GTH TX 8b/10b-assisted parallel interface, gth_clk_o domain
  // (<- sfp_1000base_x_pcs.sv txdata_o/txcharisk_o)
  input  logic [15:0] txdata_i,
  input  logic [1:0]  txcharisk_i,

  // GTH RX 8b/10b-assisted parallel interface, gth_clk_o domain
  // (-> sfp_1000base_x_pcs.sv rxdata_i/etc.)
  output logic [15:0] rxdata_o,
  output logic [1:0]  rxcharisk_o,
  output logic [1:0]  rxdisperr_o,
  output logic [1:0]  rxnotintable_o,

  // status (informational -- gth_rst_n_o already gates on tx/rx done)
  output logic gtpowergood_o,
  output logic tx_resetdone_o,
  output logic rx_resetdone_o
);

  // ---- reference clock buffer ----
  // REFCLK_EN_TX_PATH/REFCLK_HROW_CK_SEL/REFCLK_ICNTL_RX left at the
  // wizard's own example-design defaults (0/00/00) -- standard for a
  // refclk that's local to this channel's own quad, not routed to
  // another quad over the clock backbone.
  wire gtrefclk0_int;
  IBUFDS_GTE4 #(
    .REFCLK_EN_TX_PATH  (1'b0),
    .REFCLK_HROW_CK_SEL (2'b00),
    .REFCLK_ICNTL_RX    (2'b00)
  ) u_ibufds_gte4 (
    .I     (gtrefclk_p_i),
    .IB    (gtrefclk_n_i),
    .CEB   (1'b0),
    .O     (gtrefclk0_int),
    .ODIV2 ()
  );

  // ---- free-running clock buffer (DRP + reset controller) ----
  wire freerun_clk_int;
  BUFG u_bufg_freerun (
    .I (freerun_clk_i),
    .O (freerun_clk_int)
  );

  // ---- system reset -> gtwiz_reset_all_in, synchronized to freerun_clk ----
  logic [1:0] reset_all_sync_q;
  always_ff @(posedge freerun_clk_int or negedge rst_n) begin
    if (!rst_n) reset_all_sync_q <= 2'b11;
    else        reset_all_sync_q <= {reset_all_sync_q[0], 1'b0};
  end
  wire gtwiz_reset_all_int = reset_all_sync_q[1];

  // ---- IP's own userclk helper reset qualifiers (per its own example
  // design: held until this channel's PMA reset has completed) ----
  wire txpmaresetdone_int, rxpmaresetdone_int;
  wire gtwiz_userclk_tx_reset_int = ~txpmaresetdone_int;
  wire gtwiz_userclk_rx_reset_int = ~rxpmaresetdone_int;

  wire gtwiz_reset_tx_done_int, gtwiz_reset_rx_done_int;
  assign tx_resetdone_o = gtwiz_reset_tx_done_int;
  assign rx_resetdone_o = gtwiz_reset_rx_done_int;

  wire [15:0] gtwiz_userdata_rx_int;
  wire [15:0] rxctrl0_int, rxctrl1_int;
  wire [7:0]  rxctrl2_int, rxctrl3_int;

  gth_sfp_ip u_gth_sfp_ip (
    .gtwiz_userclk_tx_reset_in           (gtwiz_userclk_tx_reset_int),
    .gtwiz_userclk_tx_srcclk_out         (),
    .gtwiz_userclk_tx_usrclk_out         (),
    .gtwiz_userclk_tx_usrclk2_out        (gth_clk_o),
    .gtwiz_userclk_tx_active_out         (),
    .gtwiz_userclk_rx_reset_in           (gtwiz_userclk_rx_reset_int),
    .gtwiz_userclk_rx_srcclk_out         (),
    .gtwiz_userclk_rx_usrclk_out         (),
    .gtwiz_userclk_rx_usrclk2_out        (), // ENABLE_COMMON_USRCLK: RX
                                              // fabric interface actually
                                              // runs on the TX usrclk2
                                              // above -- see header
    .gtwiz_userclk_rx_active_out         (),

    .gtwiz_reset_clk_freerun_in          (freerun_clk_int),
    .gtwiz_reset_all_in                  (gtwiz_reset_all_int),
    .gtwiz_reset_tx_pll_and_datapath_in  (1'b0),
    .gtwiz_reset_tx_datapath_in          (1'b0),
    .gtwiz_reset_rx_pll_and_datapath_in  (1'b0),
    .gtwiz_reset_rx_datapath_in          (1'b0),
    .gtwiz_reset_rx_cdr_stable_out       (),
    .gtwiz_reset_tx_done_out             (gtwiz_reset_tx_done_int),
    .gtwiz_reset_rx_done_out             (gtwiz_reset_rx_done_int),

    .gtwiz_userdata_tx_in                (txdata_i),
    .gtwiz_userdata_rx_out               (gtwiz_userdata_rx_int),

    .drpclk_in                           (freerun_clk_int),

    .gthrxn_in                           (rxn_i),
    .gthrxp_in                           (rxp_i),
    .gtrefclk0_in                        (gtrefclk0_int),

    .rx8b10ben_in                        (1'b1),
    .rxcommadeten_in                     (1'b1),
    .rxmcommaalignen_in                  (1'b1),
    .rxpcommaalignen_in                  (1'b1),
    .tx8b10ben_in                        (1'b1),
    .txctrl0_in                          (16'h0000), // auto TX disparity
    .txctrl1_in                          (16'h0000), // (see header)
    .txctrl2_in                          ({6'b0, txcharisk_i}), // TXCHARISK, one bit/byte lane

    .gthtxn_out                          (txn_o),
    .gthtxp_out                          (txp_o),
    .gtpowergood_out                     (gtpowergood_o),

    .rxbyteisaligned_out                 (),
    .rxbyterealign_out                   (),
    .rxcommadet_out                      (),
    .rxctrl0_out                         (rxctrl0_int), // RXDISPERR
    .rxctrl1_out                         (rxctrl1_int), // RXCHARISCOMMA (unused)
    .rxctrl2_out                         (rxctrl2_int), // RXCHARISK
    .rxctrl3_out                         (rxctrl3_int), // RXNOTINTABLE
    .rxpmaresetdone_out                  (rxpmaresetdone_int),
    .txpmaresetdone_out                  (txpmaresetdone_int)
  );

  assign rxdata_o       = gtwiz_userdata_rx_int;
  assign rxcharisk_o    = rxctrl2_int[1:0];
  assign rxdisperr_o    = rxctrl0_int[1:0];
  assign rxnotintable_o = rxctrl3_int[1:0];

  // ---- gth_rst_n_o: async assert on either done signal dropping,
  // synchronous release 2 gth_clk_o cycles after both are done ----
  wire gt_done_int = gtwiz_reset_tx_done_int && gtwiz_reset_rx_done_int;
  logic [1:0] gth_rst_sync_q;
  always_ff @(posedge gth_clk_o or negedge gt_done_int) begin
    if (!gt_done_int) gth_rst_sync_q <= 2'b00;
    else               gth_rst_sync_q <= {gth_rst_sync_q[0], 1'b1};
  end
  assign gth_rst_n_o = gth_rst_sync_q[1];

endmodule
