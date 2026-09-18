// gmii_1000base_x_tx.sv
//
// IEEE 802.3 Clause 36 1000BASE-X PCS transmit process: GMII -> the code-
// group stream fed to a GTH transceiver's 8b/10b-assisted TX parallel
// interface (TXDATA/TXCHARISK; GTH's own hardware encoder does the 10-bit
// expansion). One GMII byte in, one code group out, every cycle -- no
// width conversion needed, clocked by the same 125 MHz clock as GMII/
// TXUSRCLK.
//
// Framing: /S/ (K27.7) replaces the GMII byte on the very first cycle
// tx_en is seen high (the real preamble byte that cycle is discarded, per
// spec -- the PCS receive process on the far end reconstructs preamble
// from /S/, it doesn't need to see it transmitted). Payload bytes pass
// through unchanged while tx_en stays high, substituting /V/ (K30.7,
// Error_Propagation) for any cycle tx_er is also asserted. When tx_en
// drops, /T/ (K29.7) then /R/ (K23.7) are appended, then idle resumes.
//
// Two deliberate, documented simplifications relative to the full spec
// (both wire-valid, neither affects basic framing correctness -- see
// each comment below for why):
//   1. Idle is always /I2/ (K28.5, D16.2), never alternating with /I1/.
//      Full spec-correct idle selection requires tracking running
//      disparity through arbitrary frame payload bytes to guarantee
//      comma always transmits at negative disparity, which needs the
//      complete 256-entry 8b/10b disparity table for arbitrary D-codes --
//      not something to embed from a secondhand/scraped source without
//      much more rigorous verification than was practical here. GTH's
//      hardware encoder still produces fully wire-valid, disparity-
//      bounded output for whatever symbol we choose every cycle; the
//      only cost of this simplification is that comma may occasionally
//      transmit at positive rather than the spec-preferred negative
//      disparity, which the receive side (and GTH's own comma detector,
//      when configured for both-polarity detection in the GTH wrapper
//      stage) needs to tolerate rather than reject.
//   2. The End-of-Packet-Delimiter is always /T/R/I/ (idle immediately
//      after /R/). The full spec chooses between /T/R/I/ and /T/R/R/
//      based on total frame code-group parity, for bit-error resilience
//      on the delimiter specifically -- not a basic framing-correctness
//      requirement, so left as a later refinement.

module gmii_1000base_x_tx
  import sfp_pcs_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // GMII input (from the MAC's TX side, e.g. open_eth_mac_1g's
  // gmii_txd/gmii_tx_en/gmii_tx_er outputs)
  input  logic [7:0] gmii_txd_i,
  input  logic       gmii_tx_en_i,
  input  logic       gmii_tx_er_i,

  // GTH TX 8b/10b-assisted parallel interface
  output logic [7:0] txdata_o,
  output logic        txcharisk_o
);

  typedef enum logic [1:0] {S_IDLE, S_DATA, S_EOP_R} state_t;
  state_t state_q, state_d;

  // Idle is the two-code-group /I2/ ordered set (comma, then D16.2),
  // repeating -- not a single symbol. idle_comma_q selects which half of
  // that pair is due next; it's forced back to "comma due" on every
  // entry into S_IDLE so idle always resumes cleanly on a comma boundary
  // rather than picking up mid-pair.
  logic idle_comma_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q       <= S_IDLE;
      idle_comma_q  <= 1'b1;
    end else begin
      state_q <= state_d;
      if (state_d == S_IDLE) idle_comma_q <= (state_q == S_IDLE) ? ~idle_comma_q : 1'b1;
    end
  end

  always_comb begin
    state_d = state_q;

    txdata_o    = idle_comma_q ? K28_5 : D16_2;
    txcharisk_o = idle_comma_q;

    unique case (state_q)
      S_IDLE: begin
        if (gmii_tx_en_i) begin
          txdata_o    = K27_7; // /S/, replaces this cycle's GMII byte
          txcharisk_o = 1'b1;
          state_d     = S_DATA;
        end
      end
      S_DATA: begin
        if (gmii_tx_en_i) begin
          txdata_o    = gmii_tx_er_i ? K30_7 : gmii_txd_i;
          txcharisk_o = gmii_tx_er_i;
        end else begin
          txdata_o    = K29_7; // /T/
          txcharisk_o = 1'b1;
          state_d     = S_EOP_R;
        end
      end
      S_EOP_R: begin
        txdata_o    = K23_7; // /R/
        txcharisk_o = 1'b1;
        state_d     = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

endmodule
