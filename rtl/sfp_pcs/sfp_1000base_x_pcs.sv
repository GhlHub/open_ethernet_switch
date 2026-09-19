// sfp_1000base_x_pcs.sv
//
// Wraps the hand-built 1000BASE-X PCS (TX codec, RX codec, Clause
// 36.2.5.2 sync state machine, Clause 37 auto-negotiation) behind a
// clean GMII <-> GTH-parallel-interface boundary.
//
// autoneg_1000base_x.sv (see its own header for the full design/scope-
// reduction notes) sits between gmii_1000base_x_tx.sv and the TX packer:
// while it reports an_tx_active, its own /C1//C2/ ordered-set output
// replaces gmii_1000base_x_tx.sv's entirely for that cycle. It watches
// the same rx_sym single-code-group RX stream sync_1000base_x.sv/
// gmii_1000base_x_rx.sv already consume; gmii_1000base_x_rx.sv already
// silently ignores any code group that isn't /S/ (K27.7) while idle, so
// incoming Config_Reg ordered sets never reach it as spurious frame
// data. an_link_up_o/an_duplex_full_o/an_pause_o/an_remote_fault_o are
// exposed as informational status outputs (parallel to sync_ok_o); no
// MAC TX gating is implemented on link_up -- see autoneg_1000base_x.sv's
// header.
//
// GTH-parallel-interface width/rate: verified against Vivado's own
// Transceiver Wizard (gtwizard_ultrascale) for xck26-sfvc784-2LV-c at
// 1.25 Gbps line rate / 8b10b -- the tool rejects an 8-bit (one code
// group/cycle) user-data width outright ("valid values are 16, 32, 64");
// GTHE4_CHANNEL on this part can only hand off 2 code groups/cycle at
// 62.5 MHz for this line rate, not 1/cycle at 125 MHz. This module's
// txdata_o/txcharisk_o/rxdata_i/etc. widths below match that native GT
// width/rate rather than carrying an artificial narrowing adapter --
// see rtl/sfp_pcs/gth_sfp_wrapper.sv's header for the primitive side of
// this boundary.
//
// Two clock domains:
//   - clk/rst_n (125 MHz-class): GMII and the existing byte-oriented TX/
//     RX codecs (gmii_1000base_x_tx.sv, gmii_1000base_x_rx.sv,
//     sync_1000base_x.sv) -- all three are UNCHANGED from their original
//     one-code-group-per-cycle design; this module feeds/drains them via
//     the gearbox/degearbox below rather than widening them internally,
//     to keep the (already tested) Clause 36.2.5.2 sync logic working in
//     its original, simpler one-symbol-per-cycle form.
//   - gth_clk/gth_rst_n (62.5 MHz-class, NEW): the actual GTH-parallel-
//     interface, native 2-code-groups/cycle width.
//
// gth_clk MUST be exactly clk/2, phase-related (both derived from the
// same MMCM/BUFG in the GTH wrapper stage -- see
// rtl/sfp_pcs/gth_sfp_wrapper.sv), not an independent oscillator: the
// gearbox/degearbox below is a synchronous width converter, not a true
// asynchronous CDC. Getting the exact phase right (so a gth_clk edge
// never samples mid-update) is a hardware/MMCM configuration concern,
// verified via Vivado static timing closure at implementation time --
// the same class of "assumed correctly related by construction"
// simplification this file already made for its single clk domain
// before this change; RTL alone can't prove a phase relationship, only
// documented and relied upon (same rationale as gtx_rst_n's "must
// already be synchronized by the caller" note elsewhere in this
// project). One shared lane_q toggle (clk domain) drives both the TX
// packer and RX unpacker below, so they can't drift out of phase with
// each other even if the assumed clk<->gth_clk phase turns out wrong in
// simulation -- only their relationship to gth_clk itself depends on it.
//
// Byte lane order matches this project's established word convention
// (see e.g. mac_addr_resolver.sv/ingress_port_wr.sv): lane 0 = bits
// [7:0] = the earlier-transmitted/earlier-received code group, lane 1 =
// bits [15:8] = the later one.

module sfp_1000base_x_pcs #(
  parameter logic       AN_ADV_FULL_DUPLEX  = 1'b1,
  parameter logic       AN_ADV_HALF_DUPLEX  = 1'b0,
  parameter logic [1:0] AN_ADV_PAUSE        = 2'b00,
  parameter int          AN_BREAK_LINK_CYCLES  = 8,
  parameter int          AN_LINK_TIMER_CYCLES  = 8,
  parameter int          AN_IDLE_DETECT_CYCLES = 8
) (
  input  logic clk,
  input  logic rst_n,

  input  logic gth_clk,
  input  logic gth_rst_n,

  // GMII (to/from the MAC, e.g. open_eth_mac_1g)
  input  logic [7:0] gmii_txd_i,
  input  logic       gmii_tx_en_i,
  input  logic       gmii_tx_er_i,
  output logic [7:0] gmii_rxd_o,
  output logic       gmii_rx_dv_o,
  output logic       gmii_rx_er_o,

  // GTH TX 8b/10b-assisted parallel interface, gth_clk domain, native
  // width (2 code groups/cycle -- see header)
  output logic [15:0] txdata_o,
  output logic [1:0]  txcharisk_o,

  // GTH RX 8b/10b-assisted parallel interface, gth_clk domain, ditto
  input  logic [15:0] rxdata_i,
  input  logic [1:0]  rxcharisk_i,
  input  logic [1:0]  rxdisperr_i,
  input  logic [1:0]  rxnotintable_i,

  output logic       sync_ok_o,

  // Clause 37 auto-negotiation status (informational -- see
  // autoneg_1000base_x.sv's header for what this does and doesn't cover)
  output logic       an_link_up_o,
  output logic       an_duplex_full_o,
  output logic [1:0] an_pause_o,
  output logic       an_remote_fault_o
);

  // shared clk-domain lane toggle -- see header
  logic lane_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) lane_q <= 1'b0;
    else        lane_q <= ~lane_q;
  end

  // ---- TX: gmii_1000base_x_tx.sv (unchanged) -> 2:1 packer -> gth_clk ----
  // Clause 37 auto-negotiation (autoneg_1000base_x.sv) sits ahead of the
  // packer and, while an_tx_active is high, replaces gmii_1000base_x_tx's
  // own output entirely with the /C1//C2/ ordered-set stream -- see that
  // module's header for what this mux does and doesn't guarantee (no MAC
  // TX gating; any GMII frame mid-negotiation is silently dropped here).

  logic [7:0] tx_gmii_sym;
  logic       tx_gmii_sym_k;

  gmii_1000base_x_tx u_tx (
    .clk          (clk),
    .rst_n        (rst_n),
    .gmii_txd_i   (gmii_txd_i),
    .gmii_tx_en_i (gmii_tx_en_i),
    .gmii_tx_er_i (gmii_tx_er_i),
    .txdata_o     (tx_gmii_sym),
    .txcharisk_o  (tx_gmii_sym_k)
  );

  logic       an_tx_active;
  logic [7:0] tx_an_sym;
  logic       tx_an_sym_k;

  wire [7:0] tx_sym   = an_tx_active ? tx_an_sym   : tx_gmii_sym;
  wire       tx_sym_k = an_tx_active ? tx_an_sym_k : tx_gmii_sym_k;

  logic [7:0] tx_pack_lo_q, tx_pack_hi_q;
  logic       tx_pack_lo_k_q, tx_pack_hi_k_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_pack_lo_q   <= '0;
      tx_pack_hi_q   <= '0;
      tx_pack_lo_k_q <= 1'b0;
      tx_pack_hi_k_q <= 1'b0;
    end else if (!lane_q) begin
      tx_pack_lo_q   <= tx_sym;
      tx_pack_lo_k_q <= tx_sym_k;
    end else begin
      tx_pack_hi_q   <= tx_sym;
      tx_pack_hi_k_q <= tx_sym_k;
    end
  end

  always_ff @(posedge gth_clk or negedge gth_rst_n) begin
    if (!gth_rst_n) begin
      txdata_o    <= '0;
      txcharisk_o <= '0;
    end else begin
      txdata_o    <= {tx_pack_hi_q, tx_pack_lo_q};
      txcharisk_o <= {tx_pack_hi_k_q, tx_pack_lo_k_q};
    end
  end

  // ---- RX: gth_clk capture -> 1:2 unpacker -> sync/rx codec (unchanged) ----

  logic [15:0] rx_word_q;
  logic [1:0]  rx_k_q, rx_disperr_q, rx_notintable_q;

  always_ff @(posedge gth_clk or negedge gth_rst_n) begin
    if (!gth_rst_n) begin
      rx_word_q       <= '0;
      rx_k_q          <= '0;
      rx_disperr_q    <= '0;
      rx_notintable_q <= '0;
    end else begin
      rx_word_q       <= rxdata_i;
      rx_k_q          <= rxcharisk_i;
      rx_disperr_q    <= rxdisperr_i;
      rx_notintable_q <= rxnotintable_i;
    end
  end

  wire [7:0] rx_sym            = lane_q ? rx_word_q[15:8]   : rx_word_q[7:0];
  wire       rx_sym_k          = lane_q ? rx_k_q[1]          : rx_k_q[0];
  wire       rx_sym_disperr    = lane_q ? rx_disperr_q[1]    : rx_disperr_q[0];
  wire       rx_sym_notintable = lane_q ? rx_notintable_q[1] : rx_notintable_q[0];

  logic sync_ok;
  assign sync_ok_o = sync_ok;

  sync_1000base_x u_sync (
    .clk            (clk),
    .rst_n          (rst_n),
    .rxdata_i       (rx_sym),
    .rxcharisk_i    (rx_sym_k),
    .rxdisperr_i    (rx_sym_disperr),
    .rxnotintable_i (rx_sym_notintable),
    .sync_ok_o      (sync_ok)
  );

  autoneg_1000base_x #(
    .ADV_FULL_DUPLEX    (AN_ADV_FULL_DUPLEX),
    .ADV_HALF_DUPLEX    (AN_ADV_HALF_DUPLEX),
    .ADV_PAUSE          (AN_ADV_PAUSE),
    .BREAK_LINK_CYCLES  (AN_BREAK_LINK_CYCLES),
    .LINK_TIMER_CYCLES  (AN_LINK_TIMER_CYCLES),
    .IDLE_DETECT_CYCLES (AN_IDLE_DETECT_CYCLES)
  ) u_autoneg (
    .clk              (clk),
    .rst_n            (rst_n),
    .rxdata_i         (rx_sym),
    .rxcharisk_i      (rx_sym_k),
    .rxdisperr_i      (rx_sym_disperr),
    .rxnotintable_i   (rx_sym_notintable),
    .pcs_sync_ok_i    (sync_ok),
    .an_tx_active_o   (an_tx_active),
    .txdata_o         (tx_an_sym),
    .txcharisk_o      (tx_an_sym_k),
    .link_up_o        (an_link_up_o),
    .duplex_full_o    (an_duplex_full_o),
    .pause_o          (an_pause_o),
    .remote_fault_o   (an_remote_fault_o)
  );

  gmii_1000base_x_rx u_rx (
    .clk            (clk),
    .rst_n          (rst_n),
    .rxdata_i       (rx_sym),
    .rxcharisk_i    (rx_sym_k),
    .rxdisperr_i    (rx_sym_disperr),
    .rxnotintable_i (rx_sym_notintable),
    .sync_ok_i      (sync_ok),
    .gmii_rxd_o     (gmii_rxd_o),
    .gmii_rx_dv_o   (gmii_rx_dv_o),
    .gmii_rx_er_o   (gmii_rx_er_o)
  );

endmodule
