// KR260 GTH X0Y6, 10.3125 Gb/s asynchronous 64b/66b gearbox.
// Regenerate the vendor core with ip/create_gth_10g.tcl; no 1G MMCM is used.
module gth_sfp_10g_wrapper (
 input wire freerun_clk_i,rst_n,gtrefclk_p_i,gtrefclk_n_i,
 input wire rxp_i,rxn_i, output wire txp_o,txn_o,
 input wire [63:0] txdata_i, input wire [1:0] txheader_i,
 output wire [63:0] rxdata_o, output wire [1:0] rxheader_o,
 input wire rx_bitslip_i,rx_reset_req_i,
 output wire tx_clk_o,tx_rst_n_o,rx_clk_o,rx_rst_n_o,
 output wire gtpowergood_o,tx_resetdone_o,rx_resetdone_o,locked_o
);
 wire refclk;
 IBUFDS_GTE4 refbuf (.I(gtrefclk_p_i),.IB(gtrefclk_n_i),.CEB(1'b0),.O(refclk),.ODIV2());
 // Watchdog is a one-RX-cycle event. Toggle crossing cannot miss that pulse.
 reg reset_toggle;
 always @(posedge rx_clk_o or negedge rst_n)
   if (!rst_n) reset_toggle<=0; else if (rx_reset_req_i) reset_toggle<=!reset_toggle;
 (* ASYNC_REG="TRUE" *) reg [1:0] reset_sync;
 reg reset_seen;
 reg [4:0] reset_hold;
 always @(posedge freerun_clk_i) begin
   if (!rst_n) begin reset_sync<=0;reset_seen<=0;reset_hold<=0;end
   else begin
     reset_sync<={reset_sync[0],reset_toggle};reset_seen<=reset_sync[1];
     if (reset_sync[1]!=reset_seen) reset_hold<=16;
     else if (reset_hold!=0) reset_hold<=reset_hold-1'b1;
   end
 end
 wire [5:0] header;
 wire tx_active,rx_active;
 gth_sfp_10g_ip u_gt (
  .gtwiz_reset_clk_freerun_in(freerun_clk_i),.gtwiz_reset_all_in(!rst_n),
  .gtrefclk00_in(refclk),.qpll0lock_out(locked_o),.qpll0outclk_out(),.qpll0outrefclk_out(),
  .gthrxp_in(rxp_i),.gthrxn_in(rxn_i),.gthtxp_out(txp_o),.gthtxn_out(txn_o),
  .gtpowergood_out(gtpowergood_o),
  .gtwiz_userclk_tx_reset_in(1'b0),.gtwiz_userclk_tx_srcclk_out(),.gtwiz_userclk_tx_usrclk_out(),
  .gtwiz_userclk_tx_usrclk2_out(tx_clk_o),.gtwiz_userclk_tx_active_out(tx_active),
  .gtwiz_userclk_rx_reset_in(1'b0),.gtwiz_userclk_rx_srcclk_out(),.gtwiz_userclk_rx_usrclk_out(),
  .gtwiz_userclk_rx_usrclk2_out(rx_clk_o),.gtwiz_userclk_rx_active_out(rx_active),
  .gtwiz_reset_tx_pll_and_datapath_in(1'b0),.gtwiz_reset_tx_datapath_in(1'b0),
  .gtwiz_reset_rx_pll_and_datapath_in(1'b0),.gtwiz_reset_rx_datapath_in(reset_hold!=0),
  .gtwiz_reset_rx_cdr_stable_out(),.gtwiz_reset_tx_done_out(tx_resetdone_o),.gtwiz_reset_rx_done_out(rx_resetdone_o),
  .gtwiz_userdata_tx_in(txdata_i),.txheader_in({4'b0,txheader_i}),.txsequence_in(7'b0),
  .gtwiz_userdata_rx_out(rxdata_o),.rxheader_out(header),.rxgearboxslip_in(rx_bitslip_i),
  .rxdatavalid_out(),.rxheadervalid_out(),.rxstartofseq_out(),
  .txpmaresetdone_out(),.rxpmaresetdone_out(),.txprgdivresetdone_out(),.rxprgdivresetdone_out());
 assign rxheader_o=header[1:0];
 rst_sync tx_reset (.clk(tx_clk_o),.arst_n_i(rst_n && tx_resetdone_o && tx_active),.rst_n_o(tx_rst_n_o));
 rst_sync rx_reset (.clk(rx_clk_o),.arst_n_i(rst_n && rx_resetdone_o && rx_active),.rst_n_o(rx_rst_n_o));
endmodule
