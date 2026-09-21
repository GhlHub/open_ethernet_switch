// gmii_1000base_x_tx.sv
//
// IEEE 802.3 Clause 36 1000BASE-X PCS transmit process: GMII -> the code-
// group stream fed to a GTH transceiver's 8b/10b-assisted TX parallel
// interface (TXDATA/TXCHARISK; GTH's own hardware encoder does the 10-bit
// expansion). One GMII byte in, one code group out, every cycle -- no
// width conversion needed, clocked by the same 125 MHz clock as GMII/
// TXUSRCLK.
//
// /S/ replaces a preamble byte in the even code-group position. If
// GMII starts in the odd position, finish the idle pair first and discard
// that first preamble byte. All payload/FCS bytes then pass unchanged.
// /T/ follows TX_EN deassertion; one or two /R/ symbols keep the next idle
// comma in the same even position. TX_ER propagates as /V/.
//
// This stage emits /I2/ candidates. The PCS word output tracks running
// disparity across AN and data, selecting /I1/ when needed before GTH
// performs the actual 8b/10b encoding.

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

  // Free-running code-group parity, preserved through every frame.
  // True denotes the even position occupied by idle comma or /S/.
  logic idle_comma_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q       <= S_IDLE;
      idle_comma_q  <= 1'b1;
    end else begin
      state_q <= state_d;
      idle_comma_q <= ~idle_comma_q;
    end
  end

  always_comb begin
    state_d = state_q;

    txdata_o    = idle_comma_q ? K28_5 : D16_2;
    txcharisk_o = idle_comma_q;

    unique case (state_q)
      S_IDLE: begin
        if (gmii_tx_en_i && idle_comma_q) begin
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
        if (!idle_comma_q) state_d = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

endmodule
