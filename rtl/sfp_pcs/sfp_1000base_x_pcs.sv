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
// gth_clk MUST be exactly clk/2 and phase-related (the board uses one
// MMCM). These are related-clock transfers whose setup/hold paths must
// close in implementation; they are not asynchronous CDCs. The gearbox
// commits a complete TX pair before crossing, and the unpacker retains
// the matching RX high byte when consuming the low byte. This preserves
// byte pairing at either coincident clock edge and between clock edges;
// merely meeting timing on independently updated byte registers did not.
//
// Byte lane order matches this project's established word convention
// (see e.g. mac_addr_resolver.sv/ingress_port_wr.sv): lane 0 = bits
// [7:0] = the earlier-transmitted/earlier-received code group, lane 1 =
// bits [15:8] = the later one.

module sfp_1000base_x_pcs
  import sfp_pcs_pkg::*;
#(
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

  // Two byte positions per related GTH word clock.
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

  logic [7:0] tx_pack_lo_q;
  logic       tx_pack_lo_k_q;
  logic [15:0] tx_pair_q;
  logic [1:0]  tx_pair_k_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_pack_lo_q   <= '0;
      tx_pack_lo_k_q <= 1'b0;
      tx_pair_q      <= '0;
      tx_pair_k_q    <= '0;
    end else if (!lane_q) begin
      tx_pack_lo_q   <= tx_sym;
      tx_pack_lo_k_q <= tx_sym_k;
    end else begin
      // Commit both lanes together; the slower clock must never see a
      // new low byte paired with the previous word's high byte.
      tx_pair_q   <= {tx_sym, tx_pack_lo_q};
      tx_pair_k_q <= {tx_sym_k, tx_pack_lo_k_q};
    end
  end

  // Track the disparity of the actual ordered GTH words, including AN.
  // 8b/10b changes running disparity for each unbalanced 6b/4b subcode;
  // balanced alternative encodings do not change this parity rule.
  function automatic logic rd_next(input logic rd, input logic [7:0] d,
                                    input logic k);
    logic flip6, flip4;
    begin
      case (d[4:0])
        0,1,2,4,8,15,16,23,24,27,29,30,31: flip6=1'b1;
        28: flip6=k;
        default: flip6=1'b0;
      endcase
      flip4=(d[7:5]==0 || d[7:5]==4 || d[7:5]==7);
      rd_next=rd ^ flip6 ^ flip4;
    end
  endfunction
  logic tx_rd_q, tx_comma_q;
  logic tx_rd_d, tx_comma_d;
  logic [15:0] tx_idle_word;
  always_comb begin
    tx_rd_d=tx_rd_q;
    tx_comma_d=tx_comma_q;
    tx_idle_word=tx_pair_q;
    for (int i=0; i<2; i++) begin
      // After a comma, RD- means that comma started at RD+. Use /I1/
      // (D5.6) to leave RD negative; otherwise /I2/ preserves RD-.
      if (tx_comma_d && !tx_pair_k_q[i] &&
          tx_pair_q[i*8 +: 8]==D16_2 && !tx_rd_d)
        tx_idle_word[i*8 +: 8]=D5_6;
      tx_rd_d=rd_next(tx_rd_d,tx_idle_word[i*8 +: 8],tx_pair_k_q[i]);
      tx_comma_d=tx_pair_k_q[i] && tx_idle_word[i*8 +: 8]==K28_5;
    end
  end
  always_ff @(posedge gth_clk or negedge gth_rst_n) begin
    if (!gth_rst_n) begin
      txdata_o    <= '0;
      txcharisk_o <= '0;
      tx_rd_q    <= 1'b0; // GTH encoder starts with negative disparity
      tx_comma_q <= 1'b0;
    end else begin
      txdata_o    <= tx_idle_word;
      txcharisk_o <= tx_pair_k_q;
      tx_rd_q    <= tx_rd_d;
      tx_comma_q <= tx_comma_d;
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

  logic [7:0] rx_hi_q;
  logic rx_hi_k_q, rx_hi_disperr_q, rx_hi_notintable_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_hi_q            <= '0;
      rx_hi_k_q          <= 1'b0;
      rx_hi_disperr_q    <= 1'b0;
      rx_hi_notintable_q <= 1'b0;
    end else if (!lane_q) begin
      // The GTH word register can change between the two byte reads.
      // Retain this word's high byte when its low byte is consumed.
      rx_hi_q            <= rx_word_q[15:8];
      rx_hi_k_q          <= rx_k_q[1];
      rx_hi_disperr_q    <= rx_disperr_q[1];
      rx_hi_notintable_q <= rx_notintable_q[1];
    end
  end

  wire [7:0] rx_sym            = lane_q ? rx_hi_q            : rx_word_q[7:0];
  wire       rx_sym_k          = lane_q ? rx_hi_k_q          : rx_k_q[0];
  wire       rx_sym_disperr    = lane_q ? rx_hi_disperr_q    : rx_disperr_q[0];
  wire       rx_sym_notintable = lane_q ? rx_hi_notintable_q : rx_notintable_q[0];

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
