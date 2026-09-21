// gmii_1000base_x_rx.sv
//
// IEEE 802.3 Clause 36 1000BASE-X PCS receive process: the code-group
// stream from a GTH transceiver's 8b/10b-assisted RX parallel interface
// (RXDATA/RXCHARISK/RXDISPERR/RXNOTINTABLE -- GTH's hardware decoder has
// already done the 10-to-8 bit conversion and disparity/table checking)
// -> GMII, gated by sync_1000base_x.sv's sync_ok_i. One code group in,
// one GMII byte out, every cycle.
//
// On /S/ (K27.7), pass the actual following preamble bytes through GMII
// until the received SFD. 1000BASE-X may shorten the preamble by one byte
// for an odd transmission start; synthesizing a fixed preamble/SFD instead
// silently discarded the first destination-address byte on those frames.
// The MAC synchronizes on the actual SFD rather than a fixed byte count.
// /V/ or an invalid data group marks RX error; /T/ ends the frame. Other
// control characters inside a frame abort it. Following /R/ is consumed.
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

  typedef enum logic [2:0] {S_IDLE, S_PREAMBLE, S_DATA, S_EOP_R} state_t;
  state_t state_q, state_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state_q <= S_IDLE;
    else if (!sync_ok_i) state_q <= S_IDLE;
    else state_q <= state_d;
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
        if (!rxcharisk_i && code_group_ok &&
            ((rxdata_i == 8'h55) || (rxdata_i == 8'hd5))) begin
          gmii_rx_dv_o = 1'b1;
          if (rxdata_i == 8'hd5) state_d = S_DATA;
        end else begin
          gmii_rx_er_o = 1'b1;
          state_d = S_IDLE;
        end
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
