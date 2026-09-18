// sfp_1000base_x_pcs.sv
//
// Wraps the hand-built 1000BASE-X PCS (TX codec, RX codec, Clause
// 36.2.5.2 sync state machine) behind a clean GMII <-> GTH-parallel-
// interface boundary. Does NOT instantiate the actual GTHE4_CHANNEL
// transceiver primitive -- that's a deliberately separate, later stage
// (its ~100+ parameters need cross-checking against Vivado's own
// Transceiver Wizard output for the target part, and it can't be
// meaningfully exercised by Icarus/Verilator simulation the way this
// pure PCS logic can).
//
// Clocking simplification for this stage: both TX and RX parallel
// interfaces here are assumed to already be in one shared clock domain.
// A real GTH channel's RX side is clocked from the recovered line clock
// (RXUSRCLK2, tracking the link partner's independent oscillator) and
// needs its own clock-domain crossing into the core clock domain -- GTH
// has a hardware RX elastic buffer for exactly this, configured with a
// clock-correction sequence in the GTH wrapper stage. This module's
// rxdata_i/rxcharisk_i/etc. are assumed already synchronized into `clk`
// by the time that stage exists.

module sfp_1000base_x_pcs (
  input  logic clk,
  input  logic rst_n,

  // GMII (to/from the MAC, e.g. open_eth_mac_1g)
  input  logic [7:0] gmii_txd_i,
  input  logic       gmii_tx_en_i,
  input  logic       gmii_tx_er_i,
  output logic [7:0] gmii_rxd_o,
  output logic       gmii_rx_dv_o,
  output logic       gmii_rx_er_o,

  // GTH TX 8b/10b-assisted parallel interface
  output logic [7:0] txdata_o,
  output logic       txcharisk_o,

  // GTH RX 8b/10b-assisted parallel interface
  input  logic [7:0] rxdata_i,
  input  logic       rxcharisk_i,
  input  logic       rxdisperr_i,
  input  logic       rxnotintable_i,

  output logic       sync_ok_o
);

  gmii_1000base_x_tx u_tx (
    .clk          (clk),
    .rst_n        (rst_n),
    .gmii_txd_i   (gmii_txd_i),
    .gmii_tx_en_i (gmii_tx_en_i),
    .gmii_tx_er_i (gmii_tx_er_i),
    .txdata_o     (txdata_o),
    .txcharisk_o  (txcharisk_o)
  );

  logic sync_ok;
  assign sync_ok_o = sync_ok;

  sync_1000base_x u_sync (
    .clk            (clk),
    .rst_n          (rst_n),
    .rxdata_i       (rxdata_i),
    .rxcharisk_i    (rxcharisk_i),
    .rxdisperr_i    (rxdisperr_i),
    .rxnotintable_i (rxnotintable_i),
    .sync_ok_o      (sync_ok)
  );

  gmii_1000base_x_rx u_rx (
    .clk            (clk),
    .rst_n          (rst_n),
    .rxdata_i       (rxdata_i),
    .rxcharisk_i    (rxcharisk_i),
    .rxdisperr_i    (rxdisperr_i),
    .rxnotintable_i (rxnotintable_i),
    .sync_ok_i      (sync_ok),
    .gmii_rxd_o     (gmii_rxd_o),
    .gmii_rx_dv_o   (gmii_rx_dv_o),
    .gmii_rx_er_o   (gmii_rx_er_o)
  );

endmodule
