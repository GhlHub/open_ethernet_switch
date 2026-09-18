// gmii_1000base_x_rx.sv
//
// IEEE 802.3 Clause 36 1000BASE-X PCS receive process: the code-group
// stream from a GTH transceiver's 8b/10b-assisted RX parallel interface
// (RXDATA/RXCHARISK/RXDISPERR/RXNOTINTABLE -- GTH's hardware decoder has
// already done the 10-to-8 bit conversion and disparity/table checking)
// -> GMII, gated by sync_1000base_x.sv's sync_ok_i. One code group in,
// one GMII byte out, every cycle.
//
// On /S/ (K27.7), reconstructs a preamble (six 0x55 bytes then the 0xD5
// SFD -- matching what actually remains on the wire, since /S/ itself
// already stood in for the transmit side's first preamble byte, see
// gmii_1000base_x_tx.sv) before passing subsequent code groups through
// as gmii_rxd_o, rather than passing through nothing. This is one byte
// shorter than a textbook 7-byte preamble; deliberately not padded back
// out to 7, since a receiving MAC's job is to sync on the SFD byte
// itself, not count exactly 7 bytes ahead of it -- padding back to a
// full 7 would need decoupling GMII output timing from code-group input
// timing for one cycle, for no real interoperability benefit. /V/
// (K30.7) or any invalid code group mid-frame
// propagates as gmii_rx_er_o for that cycle without ending the frame;
// /T/ (K29.7) ends it (rx_dv drops the same cycle /T/ arrives, since /T/
// itself was never payload), and the following /R/ is consumed without
// separately validating its value. Any other K-code encountered mid-
// frame (protocol violation -- e.g. an unexpected second /S/ or a stray
// comma) aborts the frame immediately (rx_er pulsed, back to idle)
// rather than passing it through as if it were data.
//
// sync_ok_i dropping at any point immediately forces rx_dv_o low and
// resets back to idle, matching the real link-down behavior a physical
// SFP unplug or a partner's TX being disabled would need.

module gmii_1000base_x_rx
  import sfp_pcs_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  input  logic [7:0] rxdata_i,
  input  logic       rxcharisk_i,
  input  logic       rxdisperr_i,
  input  logic       rxnotintable_i,
  input  logic       sync_ok_i,

  output logic [7:0] gmii_rxd_o,
  output logic       gmii_rx_dv_o,
  output logic       gmii_rx_er_o
);

  wire code_group_ok = !rxdisperr_i && !rxnotintable_i;

  typedef enum logic [2:0] {S_IDLE, S_PREAMBLE, S_SFD, S_DATA, S_EOP_R} state_t;
  state_t state_q, state_d;

  logic [2:0] preamble_cnt_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= S_IDLE;
      preamble_cnt_q <= '0;
    end else if (!sync_ok_i) begin
      state_q        <= S_IDLE;
      preamble_cnt_q <= '0;
    end else begin
      state_q <= state_d;
      if (state_q == S_PREAMBLE) begin
        preamble_cnt_q <= (preamble_cnt_q == 3'd5) ? 3'd0 : preamble_cnt_q + 1'b1;
      end
    end
  end

  always_comb begin
    state_d = state_q;

    gmii_rxd_o   = rxdata_i;
    gmii_rx_dv_o = 1'b0;
    gmii_rx_er_o = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        if (rxcharisk_i && code_group_ok && (rxdata_i == K27_7)) begin // /S/
          state_d = S_PREAMBLE;
        end
      end
      S_PREAMBLE: begin
        // 6 cycles here, not 7: /S/ itself already stood in for the
        // first preamble byte on the wire (see gmii_1000base_x_tx.sv),
        // so only 6 more 0x55s + the SFD actually follow it -- if this
        // reconstructs a full 7, it silently swallows the first real
        // payload byte while catching up to the real stream.
        gmii_rxd_o   = 8'h55;
        gmii_rx_dv_o = 1'b1;
        if (preamble_cnt_q == 3'd5) state_d = S_SFD;
      end
      S_SFD: begin
        gmii_rxd_o   = 8'hD5;
        gmii_rx_dv_o = 1'b1;
        state_d      = S_DATA;
      end
      S_DATA: begin
        if (rxcharisk_i) begin
          if (rxdata_i == K29_7 && code_group_ok) begin // /T/
            gmii_rx_dv_o = 1'b0;
            state_d      = S_EOP_R;
          end else begin
            // /V/, or any other/invalid K-code mid-frame
            if (code_group_ok && rxdata_i == K30_7) begin
              gmii_rx_dv_o = 1'b1;
              gmii_rx_er_o = 1'b1;
            end else begin
              // unexpected K-code (protocol violation): abort the frame
              gmii_rx_dv_o = 1'b0;
              gmii_rx_er_o = 1'b1;
              state_d      = S_IDLE;
            end
          end
        end else begin
          gmii_rx_dv_o = 1'b1;
          gmii_rx_er_o = !code_group_ok;
        end
      end
      S_EOP_R: begin
        gmii_rx_dv_o = 1'b0;
        state_d      = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

endmodule
