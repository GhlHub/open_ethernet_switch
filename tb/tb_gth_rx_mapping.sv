`timescale 1ns/1ps
// Vendor-boundary regression for UG576 Table 4-27. This stub models port
// semantics only; it does not model the analog transceiver or prove GT lock.
module tb_gth_rx_mapping;
  wire [1:0] k, disparity, invalid;
  gth_sfp_wrapper dut (
    .freerun_clk_i(1'b0), .rst_n(1'b0),
    .gtrefclk_p_i(1'b0), .gtrefclk_n_i(1'b0),
    .rxp_i(1'b0), .rxn_i(1'b0),
    .txdata_i(16'b0), .txcharisk_i(2'b0),
    .rxcharisk_o(k), .rxdisperr_o(disparity), .rxnotintable_o(invalid)
  );
  initial begin
    // Vary K, disparity, comma and invalid independently on both byte lanes.
    for (int flags=0; flags<256; flags++) begin
      dut.u_gth_sfp_ip.rxctrl0_out = {14'b0, flags[1:0]};
      dut.u_gth_sfp_ip.rxctrl1_out = {14'b0, flags[3:2]};
      dut.u_gth_sfp_ip.rxctrl2_out = {6'b0, flags[5:4]};
      dut.u_gth_sfp_ip.rxctrl3_out = {6'b0, flags[7:6]};
      #1;
      if (k !== flags[1:0] || disparity !== flags[3:2] || invalid !== flags[7:6])
        $fatal(1, "GTH status mapping mismatch flags=%h k=%b disparity=%b invalid=%b", flags, k, disparity, invalid);
    end
    $display("PASS: GTH K/disparity/invalid mapping independent of comma indication");
    $finish;
  end
endmodule

module IBUFDS_GTE4 #(
 parameter REFCLK_EN_TX_PATH=0, REFCLK_HROW_CK_SEL=0, REFCLK_ICNTL_RX=0
)(input I, IB, CEB, output O, ODIV2);
 assign O=I & ~CEB;
 assign ODIV2=1'b0;
endmodule
module BUFG(input I, output O);
 assign O=I;
endmodule

module gth_sfp_ip (
  input wire gtwiz_userclk_tx_reset_in,
  output logic gtwiz_userclk_tx_srcclk_out,
  output logic gtwiz_userclk_tx_usrclk_out,
  output logic gtwiz_userclk_tx_usrclk2_out,
  output logic gtwiz_userclk_tx_active_out,
  input wire gtwiz_userclk_rx_reset_in,
  output logic gtwiz_userclk_rx_srcclk_out,
  output logic gtwiz_userclk_rx_usrclk_out,
  output logic gtwiz_userclk_rx_usrclk2_out,
  output logic gtwiz_userclk_rx_active_out,
  input wire gtwiz_reset_clk_freerun_in,
  input wire gtwiz_reset_all_in,
  input wire gtwiz_reset_tx_pll_and_datapath_in,
  input wire gtwiz_reset_tx_datapath_in,
  input wire gtwiz_reset_rx_pll_and_datapath_in,
  input wire gtwiz_reset_rx_datapath_in,
  output logic gtwiz_reset_rx_cdr_stable_out,
  output logic gtwiz_reset_tx_done_out,
  output logic gtwiz_reset_rx_done_out,
  input wire [15:0] gtwiz_userdata_tx_in,
  output logic [15:0] gtwiz_userdata_rx_out,
  input wire drpclk_in,
  input wire gthrxn_in,
  input wire gthrxp_in,
  input wire gtrefclk0_in,
  input wire rxbufreset_in,
  output wire [2:0] rxbufstatus_out,
  output wire [1:0] rxclkcorcnt_out,
  input wire rx8b10ben_in,
  input wire rxcommadeten_in,
  input wire rxmcommaalignen_in,
  input wire rxpcommaalignen_in,
  input wire tx8b10ben_in,
  input wire [15:0] txctrl0_in,
  input wire [15:0] txctrl1_in,
  input wire [7:0] txctrl2_in,
  output logic gthtxn_out,
  output logic gthtxp_out,
  output logic gtpowergood_out,
  output logic rxbyteisaligned_out,
  output logic rxbyterealign_out,
  output logic rxcommadet_out,
  output logic [15:0] rxctrl0_out,
  output logic [15:0] rxctrl1_out,
  output logic [7:0] rxctrl2_out,
  output logic [7:0] rxctrl3_out,
  output logic rxpmaresetdone_out,
  output logic txpmaresetdone_out
);
endmodule
